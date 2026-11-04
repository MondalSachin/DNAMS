/**
 * @description     Rule validation steps 17-23: once no rule row is Pending, aggregates the pass rates (step 17:
 *                  overall, ExactMatch and AIMatch; NOT_APPLICABLE rows are left out, CANNOT_DECIDE counts as not
 *                  passed), sets the RAG band on each element and on the package (step 18: 100% Green, >= 85% Amber,
 *                  below Red; a failed PIR makes the package Red) and publishes them (step 19).
 *                  GREEN: package Under Review, the owner is emailed (steps 20-21) and the run moves on to transmittal
 *                  drafting (step 23, placeholder). AMBER / RED: package RMR Pending, run Completed / Needs Review with
 *                  the failed rules in Issue_Summary__c, then the AI narrative and the owner email (steps 19-22).
 *                  Element Rule_Validation_Status__c: Green Passed, Amber Needs Review, Red Failed; blank when none of
 *                  its rules applied.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
// Exception to guideline: without sharing because the system pipeline must update the package, its elements and the run regardless of ownership
public without sharing class DNAMSRuleValidationCompletionHelper {
    private static final String CLASS_NAME = DNAMSRuleValidationCompletionHelper.class.getName();
    private static final Integer NARRATIVE_LENGTH = 255;
    private static final Integer SUMMARY_LENGTH = 32768;

    /**
     * @description Pass counts for one scope (package, element or method).
     **/
    private class Tally {
        Integer applicable = 0;
        Integer passed = 0;

        void add(String verdict) {
            if (verdict == DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE) {
                return;
            }
            applicable++;
            if (verdict == DNAMSPipelineConstants.VERDICT_PASS) {
                passed++;
            }
        }

        Decimal rate() {
            return applicable == 0 ? null : (Decimal.valueOf(passed) * 100 / applicable).setScale(2);
        }
    }

    /**
     * @description Completes the rule validation stage of a Running run whose rows are all decided.
     * @param runId AI_Package_Review_Run__c id
     **/
    public static void complete(Id runId) {
        Savepoint savepoint = Database.setSavepoint();
        String health;
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            health = settle(runId);
        } catch (Exception e) {
            Database.rollback(savepoint);
            DNAMSRuleUtil.failStage(runId, e, CLASS_NAME);
            return;
        }
        if (health != null) {
            dispatch(runId, health);
        }
    }

    /**
     * @description Steps 17-19: rates, bands and the element, package and run updates.
     * @param runId The run
     * @return      The package band, or null while rows are still Pending
     **/
    private static String settle(Id runId) {
        AI_Package_Review_Run__c run = [SELECT Id, Package__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
        List<AIReviewStageResult__c> rows = [
            SELECT Id, RuleId__c, RuleName__c, ComparisonMethod__c, Verdict__c, Reasoning__c, ProcessingStatus__c,
                PackageElement__c, PackageElement__r.Name, PackageElement__r.Sort_Order__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION
            WITH SYSTEM_MODE
            ORDER BY PackageElement__r.Sort_Order__c ASC NULLS LAST, Name ASC
        ];
        Tally overall = new Tally();
        Tally exact = new Tally();
        Tally ai = new Tally();
        Map<Id, Tally> tallyByElement = new Map<Id, Tally>();
        Map<Id, List<String>> failedRulesByElement = new Map<Id, List<String>>();
        List<String> issues = new List<String>();
        Boolean pirFailed = false;
        for (AIReviewStageResult__c row : rows) {
            if (row.ProcessingStatus__c == DNAMSPipelineConstants.ROW_PENDING) {
                return null; // AIMatch still running; its job completes the stage
            }
            overall.add(row.Verdict__c);
            if (row.ComparisonMethod__c == DNAMSPipelineConstants.METHOD_EXACT) {
                exact.add(row.Verdict__c);
            } else if (row.ComparisonMethod__c == DNAMSPipelineConstants.METHOD_AI) {
                ai.add(row.Verdict__c);
            }
            Boolean isIssue = row.Verdict__c == DNAMSPipelineConstants.VERDICT_FAIL || row.Verdict__c == DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE;
            pirFailed = pirFailed || (row.RuleId__c == DNAMSPipelineConstants.PIR_RULE_ID && isIssue);
            if (row.PackageElement__c != null) {
                if (!tallyByElement.containsKey(row.PackageElement__c)) {
                    tallyByElement.put(row.PackageElement__c, new Tally());
                    failedRulesByElement.put(row.PackageElement__c, new List<String>());
                }
                tallyByElement.get(row.PackageElement__c).add(row.Verdict__c);
                if (isIssue) {
                    failedRulesByElement.get(row.PackageElement__c).add(row.RuleName__c);
                }
            }
            if (isIssue) {
                String scope = row.PackageElement__c == null ? 'Package' : row.PackageElement__r.Name;
                issues.add('- ' + scope + ' [' + row.RuleName__c + ']: ' + row.Verdict__c + ' - ' + (row.Reasoning__c ?? '').normalizeSpace());
            }
        }

        String health = pirFailed ? DNAMSPipelineConstants.HEALTH_RED : band(overall.rate());
        List<DNAMS_Package_Element__c> elements = new List<DNAMS_Package_Element__c>();
        for (Id elementId : tallyByElement.keySet()) {
            Decimal rate = tallyByElement.get(elementId).rate();
            List<String> failed = failedRulesByElement.get(elementId);
            elements.add(new DNAMS_Package_Element__c(
                Id = elementId,
                Rule_Validation_Status__c = rate == null ? null : elementStatus(band(rate)),
                Element_Narrative__c = failed.isEmpty() ? null : ('Rules not met: ' + String.join(failed, '; ')).left(NARRATIVE_LENGTH)
            ));
        }
        Boolean isGreen = health == DNAMSPipelineConstants.HEALTH_GREEN;
        DNAMS_Package__c pkg = new DNAMS_Package__c(
            Id = run.Package__c,
            Health__c = health,
            Status__c = isGreen ? DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW : DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING
        );
        if (isGreen) {
            pkg.AI_Narrative__c = null;
        }
        AI_Package_Review_Run__c runUpdate = new AI_Package_Review_Run__c(
            Id = runId,
            RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
            RuleValidationPassRate__c = overall.rate() ?? 100,
            ExactMatchPassRate__c = exact.rate(),
            AIMatchPassRate__c = ai.rate(),
            Issue_Summary__c = issues.isEmpty() ? null : String.join(issues, '\n').left(SUMMARY_LENGTH)
        );
        if (!isGreen) {
            // Steps 22: the run ends here and waits for the RMR. A Green run stays Running for transmittal drafting.
            runUpdate.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
            runUpdate.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW;
            runUpdate.Ended_At__c = System.now();
        }
        Database.update(elements, true, AccessLevel.SYSTEM_MODE);
        Database.update(pkg, true, AccessLevel.SYSTEM_MODE);
        Database.update(runUpdate, true, AccessLevel.SYSTEM_MODE);
        return health;
    }

    /**
     * @description Steps 20-23: owner email (every band) and the next job.
     * @param runId  The run
     * @param health The package band
     **/
    private static void dispatch(Id runId, String health) {
        Queueable next;
        if (health == DNAMSPipelineConstants.HEALTH_GREEN) {
            AI_Package_Review_Run__c run = [SELECT Id, Package__c, Reason__c, RuleValidationPassRate__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
            DNAMS_PackageReviewPipelineService.notifyOwners(
                new Map<Id, AI_Package_Review_Run__c>{ run.Package__c => run },
                'rule validation GREEN',
                'Package Health: GREEN\nEvery applicable validation rule passed (pass rate ' + run.RuleValidationPassRate__c + '%). The package moves on to transmittal drafting.'
            );
            next = new DNAMSTransmittalStarterQueueable(runId);
        } else {
            next = new DNAMS_PackageNarrativeQueueable(runId, 'rule validation ' + health.toUpperCase() + ' - review needed');
        }
        String notQueued = DNAMSRuleUtil.tryEnqueue(next);
        if (notQueued != null) {
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = runId;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.stage = DNAMSPipelineConstants.STAGE_RULE_VALIDATION;
            detail.sourceClass = CLASS_NAME;
            detail.message = 'The next job for this run was not queued (' + notQueued + '). The run result stands; re-run to retry.';
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
        }
    }

    /**
     * @description Step 18: RAG band from a pass rate; no applicable rule counts as Green.
     * @param rate Pass rate in percent, or null
     * @return     Green, Amber or Red
     **/
    @TestVisible
    private static String band(Decimal rate) {
        if (rate == null || rate >= DNAMSPipelineConstants.GREEN_PASS_RATE) {
            return DNAMSPipelineConstants.HEALTH_GREEN;
        }
        return rate >= DNAMSPipelineConstants.AMBER_PASS_RATE ? DNAMSPipelineConstants.HEALTH_AMBER : DNAMSPipelineConstants.HEALTH_RED;
    }

    private static String elementStatus(String health) {
        if (health == DNAMSPipelineConstants.HEALTH_GREEN) {
            return DNAMS_PackageReviewPipelineService.STAGE_PASSED;
        }
        return health == DNAMSPipelineConstants.HEALTH_AMBER ? DNAMS_PackageReviewPipelineService.STAGE_NEEDS_REVIEW : DNAMS_PackageReviewPipelineService.STAGE_FAILED;
    }
}
