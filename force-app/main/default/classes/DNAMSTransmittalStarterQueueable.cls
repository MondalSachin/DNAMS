/**
 * @description     Rule validation step 23 placeholder (GREEN 100% -> transmittal drafting), enqueued by
 *                  DNAMSRuleValidationCompletionHelper. Until the Transmittal Summary Service exists it completes the
 *                  run as Passed and records why. A run that is no longer Running is left alone (lockRun settles a
 *                  pending cancellation).
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
// Exception to guideline: without sharing because the system pipeline completes the run regardless of ownership
public without sharing class DNAMSTransmittalStarterQueueable implements Queueable {
    @TestVisible
    private static final String PLACEHOLDER_REASON = 'Rule validation passed (GREEN). Transmittal drafting not implemented yet.';
    private static final String CLASS_NAME = DNAMSTransmittalStarterQueueable.class.getName();
    private static final Integer REASON_LENGTH = Schema.SObjectType.AI_Package_Review_Run__c.fields.Reason__c.getLength();

    private Id runId;

    /**
     * @description Creates the placeholder for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSTransmittalStarterQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Completes the Running run as Passed and appends the placeholder reason.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            AI_Package_Review_Run__c run = [SELECT Id, Reason__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
            run.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
            run.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_PASSED;
            run.Ended_At__c = System.now();
            run.Reason__c = ((String.isBlank(run.Reason__c) ? '' : run.Reason__c + '\n') + PLACEHOLDER_REASON).left(REASON_LENGTH);
            Database.update(run, true, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            DNAMSRuleUtil.failStage(runId, e, CLASS_NAME);
        }
    }
}
