/**
 * @description     LLD page 5 step [17]: one-off scheduled cleanup, IDPTimeoutMinutes__c after submission. For a Running
 *                  run, rows still waiting are given one final GET (via DNAMSIDPCallbackQueueable in final-check mode):
 *                  a finished execution is processed as if its callback had arrived, a failed one becomes Error, and
 *                  one IDP still reports as running is stranded as Failed (Timeout). Rows never sent to IDP time out
 *                  directly. On a run that is no longer Running it does nothing (lockRun settles a pending cancellation).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Abhishek Dutta
 * @last modification details Final GET check before stranding waiting rows
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-04   Abhishek Dutta  Final GET check before stranding waiting rows
 **/
// Exception to guideline: without sharing because the system pipeline runs as the IDP integration user and must read all package files/records regardless of ownership
public without sharing class DNAMSExtractionCleanupJob implements Schedulable {
    private static final String CLASS_NAME = DNAMSExtractionCleanupJob.class.getName();
    private static final String JOB_NAME_PREFIX = 'DNAMS IDP cleanup ';
    private static final String CRON_FORMAT = 'ss mm HH dd MM ? yyyy';
    private static final Integer ERROR_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.ProcessingErrorDetails__c.getLength();

    private Id runId;

    /**
     * @description Creates the cleanup for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSExtractionCleanupJob(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Schedules a one-off cleanup at now + minutes (at least 1 minute ahead).
     * @param runId   AI_Package_Review_Run__c id
     * @param minutes Delay in minutes (DNAMS_Pipeline_Setting__mdt.IDPTimeoutMinutes__c)
     **/
    public static void scheduleCleanup(Id runId, Decimal minutes) {
        Integer delay = Math.max(1, minutes == null ? 1 : minutes.intValue());
        // DateTime.format uses the scheduling user's time zone, which is also how System.schedule reads the expression
        String cron = DateTime.now().addMinutes(delay).format(CRON_FORMAT);
        System.schedule(JOB_NAME_PREFIX + runId + ' ' + DateTime.now().getTime(), cron, new DNAMSExtractionCleanupJob(runId));
    }

    /**
     * @description Final check on the run's rows that are still waiting after the timeout: rows that were sent are
     *              checked with one GET (callouts are not allowed in scheduled Apex, so DNAMSIDPCallbackQueueable does
     *              it in final-check mode); rows that were never sent time out directly.
     * @param context Schedulable context
     **/
    public void execute(SchedulableContext context) {
        try {
            checkOpenRows();
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
        }
    }

    /**
     * @description Splits the waiting rows: sent rows go to the final GET check, never-sent rows time out now.
     **/
    private void checkOpenRows() {
        if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
            return;
        }
        // Only rows that have really waited the full timeout are checked, so an early or duplicate firing is harmless.
        Datetime cutoff = System.now().addMinutes(-DNAMS_PackageReviewPipelineService.settings().IDPTimeoutMinutes__c.intValue());
        Set<Id> sentRowIds = new Set<Id>();
        List<AIReviewStageResult__c> unsentRows = new List<AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT Id, ReviewRun__c, PackageElement__c, ProcessingStatus__c, DocumentTitle__c, DocumentType__c, MuleSoftExecutionId__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId
                AND Stage__c = :DNAMSPipelineConstants.STAGE_EXTRACTION
                AND ((ProcessingStatus__c = :DNAMSPipelineConstants.ROW_PENDING AND CreatedDate <= :cutoff)
                    OR (ProcessingStatus__c = :DNAMSPipelineConstants.ROW_IN_PROGRESS AND SubmittedAt__c <= :cutoff))
            WITH SYSTEM_MODE
        ]) {
            if (String.isNotBlank(row.MuleSoftExecutionId__c)) {
                sentRowIds.add(row.Id);
            } else {
                unsentRows.add(row);
            }
        }
        timeOut(unsentRows);
        if (!sentRowIds.isEmpty()) {
            // Next step: one GET per sent row; completion runs after it
            System.enqueueJob(DNAMSIDPCallbackQueueable.finalCheck(sentRowIds));
            return;
        }
        DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ runId });
    }

    /**
     * @description Marks rows that were never sent to IDP Failed (Timeout) and logs each.
     * @param rows Rows to time out
     **/
    private static void timeOut(List<AIReviewStageResult__c> rows) {
        if (rows.isEmpty()) {
            return;
        }
        List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
        for (AIReviewStageResult__c row : rows) {
            row.ProcessingErrorDetails__c = ('Never sent to IDP within the timeout; the row was still ' + row.ProcessingStatus__c + '.').left(ERROR_LENGTH);
            row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_TIMEOUT;
            row.ProcessingCompletedAt__c = System.now();
            logs.add(DNAMSErrorLogHelper.buildLog(DNAMSExtractionSubmitBatch.rowLogDetail(row, DNAMSPipelineConstants.ERROR_TIMEOUT, CLASS_NAME)));
        }
        Database.update(rows, false, AccessLevel.SYSTEM_MODE);
        DNAMSErrorLogHelper.insertLogs(logs);
    }
}
