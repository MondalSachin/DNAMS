/**
 * @description     Handler for DNAMSIDPEventTrigger. Collects the run ids of Start Extraction events and the stage
 *                  result ids of Callback events, then enqueues at most one DNAMSExtractionStarterQueueable and one
 *                  DNAMSIDPCallbackQueueable per invocation. When the queueable limit is reached the event batch is
 *                  retried instead of dropped.
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
public without sharing class DNAMSIDPEventTriggerHandler {
    /**
     * @description Routes a batch of IDP events to the extraction jobs.
     * @param events Trigger.new of DNAMSIDPEvent__e
     **/
    public static void handleEvents(List<DNAMSIDPEvent__e> events) {
        Set<Id> runIds = new Set<Id>();
        Set<Id> stageResultIds = new Set<Id>();
        for (DNAMSIDPEvent__e event : events) {
            if (event.EventType__c == DNAMSPipelineConstants.EVENT_START_EXTRACTION && String.isNotBlank(event.ReviewRunId__c)) {
                runIds.add(Id.valueOf(event.ReviewRunId__c));
            } else if (event.EventType__c == DNAMSPipelineConstants.EVENT_CALLBACK && String.isNotBlank(event.StageResultId__c)) {
                stageResultIds.add(Id.valueOf(event.StageResultId__c));
            }
        }
        if (!runIds.isEmpty()) {
            enqueue(new DNAMSExtractionStarterQueueable(runIds));
        }
        if (!stageResultIds.isEmpty()) {
            enqueue(new DNAMSIDPCallbackQueueable(stageResultIds));
        }
    }

    /**
     * @description Enqueues the job, or asks the event bus to redeliver the batch when no queueable slot is left.
     * @param job Queueable to enqueue
     **/
    private static void enqueue(Queueable job) {
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            throw new EventBus.RetryableException('Queueable job limit reached; the IDP event batch will be retried.');
        }
        System.enqueueJob(job);
    }
}
