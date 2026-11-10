/**
 * @description     Rule validation steps 2-12, enqueued by extraction completion when every document passed the
 *                  structure check (step 1). Loads the applicable DNAMSRule__mdt rules (step 3), resolves and compares
 *                  their values (steps 4-7, DNAMSRuleEvaluator), checks the PIR (steps 9-12) and saves one
 *                  AIReviewStageResult__c row per rule (step 16). AIMatch rules are saved Pending and judged by
 *                  DNAMSAIRuleValidationQueueable (steps 13-15); without them the stage completes here (steps 17-23,
 *                  DNAMSRuleValidationCompletionHelper).
 *                  PIR: not required for package types outside PIRRequiredPackageTypes__c (Not Applicable, left out of
 *                  narratives); a bypass is recorded as Not Applicable; otherwise not linked or not cleared fails, and a
 *                  PIR failure makes the package Red.
 *                  Changes Only runs (DNAMSRunChangeDetector): values are always resolved fresh and ExactMatch / PIR are
 *                  always evaluated; an AIMatch rule whose baseline verdict is reusable and whose resolved values are
 *                  unchanged is copied from the baseline (no model call). Only the rest is sent to the model.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Changes Only runs reuse unchanged AIMatch verdicts
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version (placeholder)
 * 2.0   2026-11-04   Sachin Mondal   Rule validation stage
 * 2.1   2026-11-05   Abhishek Dutta  DNAMSRuleUtil.StageFailureFinalizer
 * 2.2   2026-11-10   Abhishek Dutta  Changes Only runs reuse unchanged AIMatch verdicts
 **/
// Exception to guideline: without sharing because the system pipeline runs as the IDP integration user and must read all package files/records regardless of ownership
public without sharing class DNAMSRuleValidationStarterQueueable implements Queueable {
    private static final String CLASS_NAME = DNAMSRuleValidationStarterQueueable.class.getName();
    private static final Integer VALUE_LENGTH = 32768;

    private Id runId;
    private Boolean alreadyStarted = false;

    /**
     * @description Creates the starter for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSRuleValidationStarterQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Evaluates the rules, saves the rows, then starts AIMatch or completes the stage.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (context != null) { // null when execute is called directly rather than as a queued job
            System.attachFinalizer(new DNAMSRuleUtil.StageFailureFinalizer(runId, CLASS_NAME));
        }
        Savepoint savepoint = Database.setSavepoint();
        Boolean hasPending;
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            hasPending = startStage();
        } catch (Exception e) {
            Database.rollback(savepoint);
            DNAMSRuleUtil.failStage(runId, e, CLASS_NAME);
            return;
        }
        if (alreadyStarted) {
            return;
        }
        if (!hasPending) {
            DNAMSRuleValidationCompletionHelper.complete(runId);
            return;
        }
        String notQueued = DNAMSRuleUtil.tryEnqueue(new DNAMSAIRuleValidationQueueable(runId));
        if (notQueued != null) {
            DNAMSRuleUtil.failStage(runId, new DNAMSPipelineException('AIMatch validation was not queued: ' + notQueued), CLASS_NAME);
        }
    }

    /**
     * @description Steps 2-12 and 16: rows for every applicable rule plus the PIR row.
     * @return      Whether any AIMatch row is waiting for the model
     **/
    private Boolean startStage() {
        AI_Package_Review_Run__c run = [
            SELECT Id, Package__c, ConsolidatedExtractionJSON__c, RuleValidationProcessingStatus__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
        ];
        if (run.RuleValidationProcessingStatus__c != null) {
            alreadyStarted = true; // a duplicate start (e.g. extraction completed twice): the first one owns the stage
            return false;
        }
        DNAMS_Package__c pkg = [
            SELECT Id, Type__c, PIR_Bypass_Acknowledged__c, PIR_Bypass_Reason__c, PIR_Linked__c, PIR_Cleared__c
            FROM DNAMS_Package__c
            WHERE Id = :run.Package__c
            WITH SYSTEM_MODE
        ];
        Map<String, DNAMS_Package_Element__c> elementByType = new Map<String, DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Element_Type__r.Name
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :pkg.Id
            WITH SYSTEM_MODE
        ]) {
            elementByType.put((element.Element_Type__r?.Name ?? element.Name).trim().toLowerCase(), element);
        }

        DNAMSRuleEvaluator evaluator = new DNAMSRuleEvaluator(pkg.Id, run.ConsolidatedExtractionJSON__c);
        ReuseTally reuse = new ReuseTally(DNAMSRunChangeDetector.baselineRunIdFor(runId));
        List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        Map<Id, DNAMS_Package_Element__c> elementUpdates = new Map<Id, DNAMS_Package_Element__c>();
        Boolean hasPending = false;
        for (DNAMSRule__mdt rule : DNAMSRuleUtil.getRules()) {
            if (!DNAMSRuleUtil.appliesTo(rule, pkg.Type__c)) {
                continue;
            }
            Boolean isPackageRule = rule.RuleAppliedTo__c == DNAMSPipelineConstants.APPLIED_TO_PACKAGE;
            DNAMS_Package_Element__c element = isPackageRule ? null : elementByType.get((rule.RelativeElementType__c ?? '').trim().toLowerCase());
            AIReviewStageResult__c row = newRow(rule.DeveloperName, rule.MasterLabel, rule.ValidationMethod__c, element);
            row.RuleType__c = rule.RuleType__c;
            row.ElementType__c = rule.RelativeElementType__c;
            if (!isPackageRule && element == null) {
                setVerdict(row, DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, 'The package has no ' + rule.RelativeElementType__c + ' element.');
                reuse.evaluated++;
            } else {
                DNAMSRuleEvaluator.Outcome outcome = evaluator.evaluate(rule);
                row.SourceValue__c = outcome.sourceValue?.left(VALUE_LENGTH);
                row.ReferenceValue__c = outcome.referenceValue?.left(VALUE_LENGTH);
                AIReviewStageResult__c reused = outcome.isPending ? reuse.reusedRow(row, outcome) : null;
                if (reused != null) {
                    row = reused;
                } else if (outcome.isPending) {
                    row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_PENDING;
                    hasPending = true;
                } else {
                    setVerdict(row, outcome.verdict, outcome.reasoning);
                    reuse.evaluated++;
                }
            }
            rows.add(row);
            if (element != null) {
                elementUpdates.put(element.Id, new DNAMS_Package_Element__c(
                    Id = element.Id,
                    Current_Stage__c = DNAMSPipelineConstants.STAGE_RULE_VALIDATION,
                    Rule_Validation_Status__c = DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS
                ));
            }
        }
        rows.add(pirRow(pkg));
        reuse.evaluated++;

        Database.insert(rows, true, AccessLevel.SYSTEM_MODE);
        Database.update(elementUpdates.values(), true, AccessLevel.SYSTEM_MODE);
        Database.update(
            new AI_Package_Review_Run__c(Id = runId, RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS),
            true,
            AccessLevel.SYSTEM_MODE
        );
        if (reuse.baselineRunId != null) {
            DNAMSRunChangeDetector.appendChangeSummary(runId, DNAMSRunChangeDetector.SUMMARY_RULE_VALIDATION, reuse.summaryLine());
        }
        return hasPending;
    }

    /**
     * @description Changes Only bookkeeping for one start: the baseline's reusable AIMatch verdicts and the counts for
     *              the ChangeSummary__c line. With no baseline (All run) nothing is ever reused.
     **/
    private class ReuseTally {
        Id baselineRunId;
        Map<String, AIReviewStageResult__c> reusableByRule = new Map<String, AIReviewStageResult__c>();
        Integer reused = 0;
        Integer evaluated = 0;
        List<String> recheckReasons = new List<String>();

        /**
         * @description Loads the baseline's reusable AIMatch rows (none for an All run).
         * @param baselineRunId DNAMSRunChangeDetector.baselineRunIdFor(runId); null for an All run
         **/
        ReuseTally(Id baselineRunId) {
            this.baselineRunId = baselineRunId;
            if (baselineRunId != null) {
                reusableByRule = DNAMSRunChangeDetector.reusableRuleRows(baselineRunId);
            }
        }

        /**
         * @description The baseline verdict copied into this run when the resolved values are unchanged; otherwise
         *              null (the rule goes to the model) and, on a Changes Only run, the reason is recorded.
         * @param row     The new row with this run's rule, element and resolved values
         * @param outcome The resolved AIMatch outcome
         * @return        Unsaved reused row, or null
         **/
        AIReviewStageResult__c reusedRow(AIReviewStageResult__c row, DNAMSRuleEvaluator.Outcome outcome) {
            if (baselineRunId == null) {
                return null;
            }
            AIReviewStageResult__c baselineRow = reusableByRule.get(row.RuleId__c);
            if (!DNAMSRunChangeDetector.ruleStillValid(baselineRow, outcome.sourceValue, outcome.referenceValue)) {
                recheckReasons.add(row.RuleId__c + ': ' + (baselineRow == null ? 'no earlier AI verdict' : 'values changed'));
                return null;
            }
            reused++;
            AIReviewStageResult__c copy = DNAMSRunChangeDetector.cloneForReuse(baselineRow, row.ReviewRun__c);
            // The rule and element of this run (same values; the element id is the current one)
            copy.PackageElement__c = row.PackageElement__c;
            copy.RuleName__c = row.RuleName__c;
            copy.RuleType__c = row.RuleType__c;
            copy.ElementType__c = row.ElementType__c;
            return copy;
        }

        /**
         * @description ChangeSummary__c text, e.g. "26 reused, 4 re-checked (DA_V01: values changed), 12 exact/PIR evaluated".
         * @return      The line text
         **/
        String summaryLine() {
            return reused + ' reused, ' + recheckReasons.size() + ' re-checked' +
                (recheckReasons.isEmpty() ? '' : ' (' + String.join(recheckReasons, '; ') + ')') +
                ', ' + evaluated + ' exact/PIR evaluated';
        }
    }

    /**
     * @description Steps 9-12: the PIR check for the package.
     * @param pkg The package with its PIR fields
     * @return    The PIR row
     **/
    @TestVisible
    private AIReviewStageResult__c pirRow(DNAMS_Package__c pkg) {
        AIReviewStageResult__c row = newRow(DNAMSPipelineConstants.PIR_RULE_ID, DNAMSPipelineConstants.PIR_RULE_NAME, DNAMSPipelineConstants.METHOD_PIR, null);
        row.RuleType__c = DNAMSPipelineConstants.RULE_TYPE_VALIDATION;
        row.SourceValue__c = 'Linked: ' + pkg.PIR_Linked__c + ', Cleared: ' + pkg.PIR_Cleared__c + ', Bypass acknowledged: ' + pkg.PIR_Bypass_Acknowledged__c;
        row.ReferenceValue__c = 'PIR required for: ' + (DNAMS_PackageReviewPipelineService.settings().PIRRequiredPackageTypes__c ?? '(none)');
        if (pkg.Type__c == null || !DNAMSRuleUtil.pirRequiredTypes().contains(pkg.Type__c.toLowerCase())) {
            setVerdict(row, DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE, 'PIR is not required for package type ' + pkg.Type__c + '.');
        } else if (pkg.PIR_Bypass_Acknowledged__c) {
            setVerdict(row, DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE,
                'PIR bypass acknowledged' + (String.isBlank(pkg.PIR_Bypass_Reason__c) ? '.' : ': ' + pkg.PIR_Bypass_Reason__c));
        } else if (!pkg.PIR_Linked__c) {
            setVerdict(row, DNAMSPipelineConstants.VERDICT_FAIL, 'No eligible PIR is linked to the package and no bypass is acknowledged.');
        } else if (!pkg.PIR_Cleared__c) {
            setVerdict(row, DNAMSPipelineConstants.VERDICT_FAIL, 'The linked PIR has not cleared and no bypass is acknowledged.');
        } else {
            setVerdict(row, DNAMSPipelineConstants.VERDICT_PASS, 'An eligible PIR is linked and cleared.');
        }
        return row;
    }

    private AIReviewStageResult__c newRow(String ruleId, String ruleName, String method, DNAMS_Package_Element__c element) {
        return new AIReviewStageResult__c(
            ReviewRun__c = runId,
            Stage__c = DNAMSPipelineConstants.STAGE_RULE_VALIDATION,
            RuleId__c = ruleId,
            RuleName__c = ruleName,
            ComparisonMethod__c = method,
            PackageElement__c = element?.Id
        );
    }

    private static void setVerdict(AIReviewStageResult__c row, String verdict, String reasoning) {
        row.Verdict__c = verdict;
        row.Reasoning__c = reasoning?.left(VALUE_LENGTH);
        row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED;
        row.ProcessingCompletedAt__c = System.now();
    }
}