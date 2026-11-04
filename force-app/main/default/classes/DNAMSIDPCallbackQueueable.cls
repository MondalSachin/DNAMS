/**
 * @description     LLD page 5 steps [13]-[16]: after an IDP callback, GETs the execution result of each stage row that is
 *                  still In Progress on a Running run (callouts first, then DML), stores the raw result and maps the
 *                  IDP status: SUCCEEDED → Completed; failed statuses or an HTTP error → Error with an IDP Failure log;
 *                  pending statuses → left In Progress for a later callback or the timeout cleanup. Then asks
 *                  completion to settle the affected runs.
 *                  Integration: DNAMSIDPActionUtil.getClient() (Named Credential DNAMS_Pipeline_Setting__mdt.IDPNamedCredential__c).
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
public without sharing class DNAMSIDPCallbackQueueable implements Queueable, Database.AllowsCallouts {
    private static final String CLASS_NAME = DNAMSIDPCallbackQueueable.class.getName();
    private static final Integer RAW_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.RawStageResponseJSON__c.getLength();
    private static final Integer ERROR_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.ProcessingErrorDetails__c.getLength();
    private static final Integer STATUS_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.MuleSoftExecutionStatus__c.getLength();
    private static final Integer PAYLOAD_LENGTH = Schema.SObjectType.AIReviewErrorLog__c.fields.RawPayload__c.getLength();

    private Set<Id> stageResultIds;
    private Boolean isFinalCheck;

    /**
     * @description Processes callbacks for the given stage rows (a row whose execution is still running stays In Progress).
     * @param stageResultIds AIReviewStageResult__c ids from Callback events
     **/
    public DNAMSIDPCallbackQueueable(Set<Id> stageResultIds) {
        this.stageResultIds = stageResultIds == null ? new Set<Id>() : stageResultIds;
        this.isFinalCheck = false;
    }

    /**
     * @description Final-check job for the timeout cleanup: an execution IDP still reports as running is stranded as
     *              Failed (Timeout) instead of being left In Progress.
     * @param stageResultIds AIReviewStageResult__c ids still waiting after the timeout
     * @return               The queueable to enqueue
     **/
    public static DNAMSIDPCallbackQueueable finalCheck(Set<Id> stageResultIds) {
        DNAMSIDPCallbackQueueable job = new DNAMSIDPCallbackQueueable(stageResultIds);
        job.isFinalCheck = true;
        return job;
    }

    /**
     * @description Fetches, records and completes. Late or duplicate callbacks (row no longer In Progress, run not
     *              Running) are ignored.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (stageResultIds.isEmpty()) {
            return;
        }
        Set<Id> runIds = new Set<Id>();
        try {
            List<AIReviewStageResult__c> rows = [
                SELECT Id, ReviewRun__c, PackageElement__c, IDPActionName__c, MuleSoftExecutionId__c, DocumentTitle__c, DocumentType__c
                FROM AIReviewStageResult__c
                WHERE Id IN :stageResultIds
                    AND ProcessingStatus__c = :DNAMSPipelineConstants.ROW_IN_PROGRESS
                    AND ReviewRun__r.Status__c = :DNAMS_PackageReviewPipelineService.RUN_RUNNING
                WITH SYSTEM_MODE
            ];
            if (rows.isEmpty()) {
                return;
            }
            for (AIReviewStageResult__c row : rows) {
                runIds.add(row.ReviewRun__c);
            }
            if (context != null) { // null when execute is called directly rather than as a queued job
                System.attachFinalizer(new DNAMSExtractionStarterQueueable.RunFailureFinalizer(runIds, CLASS_NAME));
            }
            Map<Id, DNAMSIDPWrapper.ExecutionResult> resultByRowId = fetchAll(rows);
            List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
            for (AIReviewStageResult__c row : rows) {
                AIReviewErrorLog__c log = applyResult(row, resultByRowId.get(row.Id), isFinalCheck);
                if (log != null) {
                    logs.add(log);
                }
            }
            Database.update(rows, false, AccessLevel.SYSTEM_MODE);
            DNAMSErrorLogHelper.insertLogs(logs);
            DNAMSExtractionCompletionHelper.completeExtraction(runIds);
        } catch (Exception e) {
            // shortcut: one log + failRun per run; the subscriber delivers one event per batch, so this is a single run
            for (Id runId : runIds) {
                DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
            }
        }
    }

    /**
     * @description Step [14]: one GET per row. A row whose action is no longer active fails locally without a callout.
     * @param rows In Progress stage rows
     * @return     GET outcome per row id
     **/
    private static Map<Id, DNAMSIDPWrapper.ExecutionResult> fetchAll(List<AIReviewStageResult__c> rows) {
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByName = new Map<String, DNAMSIDPWrapper.ActionConfig>();
        for (DNAMSIDPWrapper.ActionConfig action : DNAMSIDPActionUtil.getActionsByDocumentType().values()) {
            actionByName.put(action.developerName, action);
        }
        IDocumentExtractionClient client = DNAMSIDPActionUtil.getClient();
        Map<Id, DNAMSIDPWrapper.ExecutionResult> resultByRowId = new Map<Id, DNAMSIDPWrapper.ExecutionResult>();
        for (AIReviewStageResult__c row : rows) {
            DNAMSIDPWrapper.ActionConfig action = actionByName.get(row.IDPActionName__c);
            DNAMSIDPWrapper.ExecutionResult result;
            if (action == null) {
                result = new DNAMSIDPWrapper.ExecutionResult();
                result.isSuccess = false;
                result.errorMessage = 'No active IDP action named ' + row.IDPActionName__c + '.';
            } else {
                // Callout to MuleSoft IDP (or the stub): read the execution result
                result = client.fetchExecution(action, row.MuleSoftExecutionId__c);
            }
            resultByRowId.put(row.Id, result);
        }
        return resultByRowId;
    }

    /**
     * @description Maps one GET outcome onto the row: SUCCEEDED -> Completed; still running -> unchanged, or stranded as
     *              Failed (Timeout) in final-check mode; any failure -> Error with an IDP Failure log.
     * @param row          Stage row (updated in memory)
     * @param result       GET outcome
     * @param isFinalCheck True when the timeout cleanup asked for this check
     * @return             Error log to insert, or null
     **/
    private static AIReviewErrorLog__c applyResult(AIReviewStageResult__c row, DNAMSIDPWrapper.ExecutionResult result, Boolean isFinalCheck) {
        String status = result.executionStatus?.toUpperCase();
        row.MuleSoftExecutionStatus__c = status?.left(STATUS_LENGTH);
        Boolean isSuccess = result.isSuccess == true;
        if (isSuccess && DNAMSPipelineConstants.IDP_PENDING_STATUSES.contains(status)) {
            // still running at IDP: a later callback settles it, unless the timeout has passed (final check)
            return isFinalCheck ? strand(row, status) : null;
        }
        row.RawStageResponseJSON__c = result.responseBody?.left(RAW_LENGTH);
        row.ProcessingCompletedAt__c = System.now();
        if (isSuccess && status == DNAMSPipelineConstants.IDP_SUCCEEDED) {
            row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_COMPLETED;
            return null;
        }
        String message;
        if (!isSuccess) {
            message = 'IDP result could not be read' + (result.statusCode == null ? '' : ' (HTTP ' + result.statusCode + ')') + ': ' + result.errorMessage;
        } else if (DNAMSPipelineConstants.IDP_FAILED_STATUSES.contains(status)) {
            message = 'IDP execution ended with status ' + status + '.';
        } else {
            message = 'IDP returned an unexpected execution status: ' + status + '.';
        }
        row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_ERROR;
        row.ProcessingErrorDetails__c = message.left(ERROR_LENGTH);
        DNAMSErrorLogHelper.LogDetail detail = DNAMSExtractionSubmitBatch.rowLogDetail(row, DNAMSPipelineConstants.ERROR_IDP_FAILURE, CLASS_NAME);
        detail.rawPayload = result.responseBody?.left(PAYLOAD_LENGTH);
        return DNAMSErrorLogHelper.buildLog(detail);
    }

    /**
     * @description Strands a row whose execution IDP still reports as running after the timeout.
     * @param row    Stage row (updated in memory)
     * @param status IDP execution status
     * @return       Timeout error log
     **/
    private static AIReviewErrorLog__c strand(AIReviewStageResult__c row, String status) {
        row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_TIMEOUT;
        row.ProcessingCompletedAt__c = System.now();
        row.ProcessingErrorDetails__c = ('IDP still reported ' + status + ' after the timeout; the row was stranded.').left(ERROR_LENGTH);
        return DNAMSErrorLogHelper.buildLog(DNAMSExtractionSubmitBatch.rowLogDetail(row, DNAMSPipelineConstants.ERROR_TIMEOUT, CLASS_NAME));
    }
}
