/**
 * @description     Rule validation steps 13-15: judges the run's Pending AIMatch rule rows with the rule validation
 *                  prompt, at most RuleValidationBatchSize__c comparisons per call (default 50). Each comparison sends
 *                  the rule id, name, description, AI instruction, comparator and the resolved values. The model call
 *                  is retried up to Max_Attempts__c; a rule without a usable verdict becomes CANNOT_DECIDE. Chains
 *                  itself while rows remain Pending, then completes the stage (DNAMSRuleValidationCompletionHelper).
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Crash finalizer fails the rule validation stage, not extraction
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 * 1.1   2026-11-05   Abhishek Dutta  DNAMSRuleUtil.StageFailureFinalizer
 **/
// Exception to guideline: without sharing because the system pipeline must update every rule row of the run regardless of ownership
public without sharing class DNAMSAIRuleValidationQueueable implements Queueable, Database.AllowsCallouts {
    private static final String CLASS_NAME = DNAMSAIRuleValidationQueueable.class.getName();
    private static final Set<String> MODEL_VERDICTS = new Set<String>{
        DNAMSPipelineConstants.VERDICT_PASS,
        DNAMSPipelineConstants.VERDICT_FAIL,
        DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE
    };

    @TestVisible
    private static DNAMSRuleAIValidator validator = new DNAMSEinsteinRuleAIValidator();

    private Id runId;

    /**
     * @description Creates the job for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSAIRuleValidationQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Judges one batch of Pending rows (model calls before any DML), then chains or completes.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (context != null) {
            System.attachFinalizer(new DNAMSRuleUtil.StageFailureFinalizer(runId, CLASS_NAME));
        }
        Boolean morePending;
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            morePending = judgeBatch();
        } catch (Exception e) {
            DNAMSRuleUtil.failStage(runId, e, CLASS_NAME);
            return;
        }
        if (!morePending) {
            DNAMSRuleValidationCompletionHelper.complete(runId);
            return;
        }
        String notQueued = DNAMSRuleUtil.tryEnqueue(new DNAMSAIRuleValidationQueueable(runId));
        if (notQueued != null) {
            DNAMSRuleUtil.failStage(runId, new DNAMSPipelineException('The next AIMatch batch was not queued: ' + notQueued), CLASS_NAME);
        }
    }

    /**
     * @description Judges up to one batch of Pending rows.
     * @return      Whether Pending rows remain after this batch
     **/
    private Boolean judgeBatch() {
        DNAMS_Pipeline_Setting__mdt settings = DNAMS_PackageReviewPipelineService.settings();
        Integer batchSize = (settings.RuleValidationBatchSize__c ?? DNAMSPipelineConstants.DEFAULT_RULE_BATCH_SIZE).intValue();
        List<AIReviewStageResult__c> rows = pendingRows(batchSize + 1);
        if (rows.isEmpty()) {
            return false;
        }
        Boolean morePending = rows.size() > batchSize;
        if (morePending) {
            rows.remove(rows.size() - 1);
        }

        Map<String, DNAMSRule__mdt> rulesById = DNAMSRuleUtil.getRulesById();
        List<Map<String, Object>> comparisons = new List<Map<String, Object>>();
        for (AIReviewStageResult__c row : rows) {
            DNAMSRule__mdt rule = rulesById.get(row.RuleId__c);
            comparisons.add(new Map<String, Object>{
                'rule_id' => row.RuleId__c,
                'rule_name' => row.RuleName__c,
                'description' => rule?.Description__c,
                'ai_instruction' => rule?.AIInstructions__c,
                'comparator' => rule?.Comparator__c,
                'source_value' => row.SourceValue__c,
                'reference_value' => row.ReferenceValue__c
            });
        }

        String failure;
        Map<String, Map<String, Object>> verdictsByRuleId;
        Integer attempts = Math.max(1, (settings.Max_Attempts__c ?? 1).intValue());
        for (Integer attempt = 1; attempt <= attempts && verdictsByRuleId == null; attempt++) {
            try {
                verdictsByRuleId = parse(validator.validate(settings.RuleValidationPromptTemplate__c, JSON.serialize(comparisons)));
            } catch (Exception e) {
                failure = 'AI call failed after ' + attempt + ' attempt(s): ' + e.getTypeName() + ': ' + e.getMessage();
            }
        }

        for (AIReviewStageResult__c row : rows) {
            Map<String, Object> answer = verdictsByRuleId?.get(row.RuleId__c);
            String verdict = answer == null ? null : String.valueOf(answer.get('verdict') ?? '').trim().toUpperCase();
            if (verdict == null || !MODEL_VERDICTS.contains(verdict)) {
                row.Verdict__c = DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE;
                row.Reasoning__c = failure ?? 'The model returned no usable verdict for this rule.';
            } else {
                row.Verdict__c = verdict;
                row.Reasoning__c = String.valueOf(answer.get('reasoning') ?? '').left(32768);
            }
            row.RawStageResponseJSON__c = answer == null ? null : JSON.serialize(answer);
            row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED;
            row.ProcessingCompletedAt__c = System.now();
        }
        Database.update(rows, true, AccessLevel.SYSTEM_MODE);
        return morePending;
    }

    private List<AIReviewStageResult__c> pendingRows(Integer limitSize) {
        return [
            SELECT Id, RuleId__c, RuleName__c, SourceValue__c, ReferenceValue__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId
                AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION
                AND ProcessingStatus__c = :DNAMSPipelineConstants.ROW_PENDING
            WITH SYSTEM_MODE
            ORDER BY Name
            LIMIT :limitSize
        ];
    }

    /**
     * @description Reads the model's JSON array (code fences or text around it are ignored).
     * @param raw The model text
     * @return    Answers keyed by rule_id
     * @throws DNAMSPipelineException when no JSON array can be read
     **/
    @TestVisible
    private static Map<String, Map<String, Object>> parse(String raw) {
        Integer start = raw?.indexOf('[') ?? -1;
        Integer finish = raw?.lastIndexOf(']') ?? -1;
        if (start < 0 || finish <= start) {
            throw new DNAMSPipelineException('The model answer is not a JSON array.');
        }
        Map<String, Map<String, Object>> byRuleId = new Map<String, Map<String, Object>>();
        for (Object item : (List<Object>) JSON.deserializeUntyped(raw.substring(start, finish + 1))) {
            if (item instanceof Map<String, Object>) {
                Map<String, Object> answer = (Map<String, Object>) item;
                if (answer.get('rule_id') != null) {
                    byRuleId.put(String.valueOf(answer.get('rule_id')).trim(), answer);
                }
            }
        }
        return byRuleId;
    }
}
