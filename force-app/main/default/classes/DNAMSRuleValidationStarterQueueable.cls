/**
 * @description     Phase 3 placeholder, enqueued by extraction completion when every document passed. Until rule
 *                  validation exists it completes the run as Passed and records why. A run that is no longer Running
 *                  (for example cancelled during extraction) is left alone; lockRun settles a pending cancellation.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
// Exception to guideline: without sharing because the system pipeline runs as the IDP integration user and must read all package files/records regardless of ownership
public without sharing class DNAMSRuleValidationStarterQueueable implements Queueable {
    @TestVisible
    private static final String PLACEHOLDER_REASON = 'Extraction completed. Rule validation not implemented yet.';
    private static final String CLASS_NAME = DNAMSRuleValidationStarterQueueable.class.getName();
    private static final Integer REASON_LENGTH = Schema.SObjectType.AI_Package_Review_Run__c.fields.Reason__c.getLength();

    private Id runId;

    /**
     * @description Creates the placeholder for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSRuleValidationStarterQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Completes the Running run as Passed and appends the placeholder reason.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (context != null) { // null when execute is called directly rather than as a queued job
            System.attachFinalizer(new DNAMSExtractionStarterQueueable.RunFailureFinalizer(new Set<Id>{ runId }, CLASS_NAME));
        }
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            List<AI_Package_Review_Run__c> runs = [SELECT Id, Reason__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
            AI_Package_Review_Run__c run = runs[0];
            run.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
            run.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_PASSED;
            run.Ended_At__c = System.now();
            run.Reason__c = ((String.isBlank(run.Reason__c) ? '' : run.Reason__c + '\n') + PLACEHOLDER_REASON).left(REASON_LENGTH);
            Database.update(run, true, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
        }
    }
}
