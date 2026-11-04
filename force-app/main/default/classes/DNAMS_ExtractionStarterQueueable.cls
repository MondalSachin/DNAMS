/**
 * Diagram step 23: starts the extraction process after a run passes classification.
 * Placeholder until the extraction slice is designed; it only records that extraction was requested.
 */
public without sharing class DNAMS_ExtractionStarterQueueable implements Queueable {
    private final Id runId;

    public DNAMS_ExtractionStarterQueueable(Id runId) {
        this.runId = runId;
    }

    public void execute(QueueableContext context) {
        AI_Package_Review_Run__c run = [SELECT Reason__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
        run.Reason__c = ((String.isBlank(run.Reason__c) ? '' : run.Reason__c + '\n') +
            'Classification passed. Extraction requested (not implemented yet).').left(4000);
        update run;
    }
}