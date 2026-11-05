/**
 * @description     LLD page 5 steps [6]-[9]: POSTs each Pending extraction stage row's file to its MuleSoft IDP action,
 *                  with a signed callback URL. All callouts of a scope run first, then one DML: success moves the row to
 *                  In Progress, failure to Error with a POST Error log. finish() schedules the timeout cleanup and asks
 *                  completion to settle the run (it waits while rows are still in flight). In Stub mode each submitted
 *                  row also gets a simulated Callback event, since the stub IDP never calls back.
 *                  Integration: DNAMSIDPActionUtil.getClient() (Named Credential DNAMS_Pipeline_Setting__mdt.IDPNamedCredential__c).
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Stub mode simulates the IDP callback instead of waiting for the timeout cleanup
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-05   Abhishek Dutta  Stub mode simulates the IDP callback instead of waiting for the timeout cleanup
 **/
// Exception to guideline: without sharing because the system pipeline runs as the IDP integration user and must read all package files/records regardless of ownership
public without sharing class DNAMSExtractionSubmitBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    private static final String CLASS_NAME = DNAMSExtractionSubmitBatch.class.getName();
    private static final Integer ERROR_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.ProcessingErrorDetails__c.getLength();
    private static final Integer STATUS_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.MuleSoftExecutionStatus__c.getLength();
    private static final Integer PAYLOAD_LENGTH = Schema.SObjectType.AIReviewErrorLog__c.fields.RawPayload__c.getLength();

    private Id runId;

    /**
     * @description Creates the submit batch for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSExtractionSubmitBatch(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Pending Extraction rows of the run.
     * @param context Batch context
     * @return        Query locator over the rows
     **/
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator(
            [
                SELECT Id, ReviewRun__c, PackageElement__c, IDPActionName__c, IDPActionId__c, IDPActionVersion__c, CallbackToken__c,
                    ContentVersionId__c, DocumentTitle__c, DocumentType__c
                FROM AIReviewStageResult__c
                WHERE ReviewRun__c = :runId
                    AND Stage__c = :DNAMSPipelineConstants.STAGE_EXTRACTION
                    AND ProcessingStatus__c = :DNAMSPipelineConstants.ROW_PENDING
                WITH SYSTEM_MODE
            ]
        );
    }

    /**
     * @description Submits the scope's files (callouts first), then saves the outcomes and error logs in one DML each.
     *              Works for any scope size; the default scope of 1 keeps one file body in heap at a time.
     * @param context Batch context
     * @param rows    Pending stage rows
     **/
    public void execute(Database.BatchableContext context, List<AIReviewStageResult__c> rows) {
        if (!DNAMS_PackageReviewPipelineService.isRunning(runId)) {
            return; // cancelled or failed; the cleanup job or the canceller settles the run
        }
        try {
            Map<Id, DNAMSIDPWrapper.SubmitResult> resultByRowId = submitAll(rows);
            List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
            for (AIReviewStageResult__c row : rows) {
                AIReviewErrorLog__c log = applyResult(row, resultByRowId.get(row.Id));
                if (log != null) {
                    logs.add(log);
                }
            }
            List<Database.SaveResult> saved = Database.update(rows, false, AccessLevel.SYSTEM_MODE);
            DNAMSErrorLogHelper.insertLogs(logs);
            simulateStubCallbacks(rows, saved);
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
        }
    }

    /**
     * @description Stub mode only: the stub IDP never calls back, so without this the run waits for the timeout
     *              cleanup. Publishes the same Callback event DNAMSIDPCallbackAPI publishes, one per submitted row; it is
     *              delivered after this transaction commits and the normal callback path follows. Live mode waits for
     *              MuleSoft's real callback. A failed publish is logged and left to the timeout cleanup.
     * @param rows  The scope's rows after applyResult
     * @param saved Save results of the rows, in the same order
     * @return      Number of Callback events published (0 in Live mode)
     **/
    @TestVisible
    private Integer simulateStubCallbacks(List<AIReviewStageResult__c> rows, List<Database.SaveResult> saved) {
        if (DNAMS_PackageReviewPipelineService.settings().IDPMode__c == DNAMSPipelineConstants.IDP_MODE_LIVE) {
            return 0;
        }
        List<DNAMSIDPEvent__e> events = new List<DNAMSIDPEvent__e>();
        for (Integer index = 0; index < rows.size(); index++) {
            if (saved[index].isSuccess() && rows[index].ProcessingStatus__c == DNAMSPipelineConstants.ROW_IN_PROGRESS) {
                events.add(
                    new DNAMSIDPEvent__e(
                        EventType__c = DNAMSPipelineConstants.EVENT_CALLBACK,
                        ReviewRunId__c = runId,
                        StageResultId__c = rows[index].Id
                    )
                );
            }
        }
        if (events.isEmpty()) {
            return 0;
        }
        Integer published = 0;
        List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
        for (Database.SaveResult result : EventBus.publish(events)) {
            if (result.isSuccess()) {
                published++;
                continue;
            }
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = runId;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.sourceClass = CLASS_NAME;
            detail.message = 'Stub callback event publish failed; the timeout cleanup settles the row: ' + result.getErrors()[0].getMessage();
            logs.add(DNAMSErrorLogHelper.buildLog(detail));
        }
        DNAMSErrorLogHelper.insertLogs(logs);
        return published;
    }

    /**
     * @description Schedules the one-off timeout cleanup, then lets completion settle the run if nothing is in flight.
     * @param context Batch context
     **/
    public void finish(Database.BatchableContext context) {
        try {
            DNAMSExtractionCleanupJob.scheduleCleanup(runId, DNAMS_PackageReviewPipelineService.settings().IDPTimeoutMinutes__c);
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ runId });
        } catch (Exception e) {
            DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
        }
    }

    /**
     * @description Error log detail prefilled from a stage row (message = its ProcessingErrorDetails__c); shared by the
     *              extraction orchestration classes.
     * @param row         Stage row the log is about
     * @param errorType   AIReviewErrorLog__c.ErrorType__c value (DNAMSPipelineConstants.ERROR_*)
     * @param sourceClass Class that raised the error
     * @return            Log detail ready for DNAMSErrorLogHelper.buildLog
     **/
    public static DNAMSErrorLogHelper.LogDetail rowLogDetail(AIReviewStageResult__c row, String errorType, String sourceClass) {
        DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
        detail.runId = row.ReviewRun__c;
        detail.elementId = row.PackageElement__c;
        detail.stageResultId = row.Id;
        detail.errorType = errorType;
        detail.sourceClass = sourceClass;
        detail.message = row.ProcessingErrorDetails__c;
        detail.documentTitle = row.DocumentTitle__c;
        detail.documentType = row.DocumentType__c;
        return detail;
    }

    /**
     * @description POSTs every row's file. File bodies for the whole scope come from one ContentVersion query.
     * @param rows Pending stage rows
     * @return     Submit outcome per row id
     **/
    private static Map<Id, DNAMSIDPWrapper.SubmitResult> submitAll(List<AIReviewStageResult__c> rows) {
        Set<Id> versionIds = new Set<Id>();
        for (AIReviewStageResult__c row : rows) {
            versionIds.add(Id.valueOf(row.ContentVersionId__c));
        }
        Map<Id, ContentVersion> versionById = new Map<Id, ContentVersion>([SELECT Id, VersionData FROM ContentVersion WHERE Id IN :versionIds WITH SYSTEM_MODE]);
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByName = new Map<String, DNAMSIDPWrapper.ActionConfig>();
        for (DNAMSIDPWrapper.ActionConfig action : DNAMSIDPActionUtil.getActionsByDocumentType().values()) {
            actionByName.put(action.developerName, action);
        }
        String baseUrl = DNAMS_PackageReviewPipelineService.settings().IDPCallbackSiteURL__c;
        IDocumentExtractionClient client = DNAMSIDPActionUtil.getClient();

        Map<Id, DNAMSIDPWrapper.SubmitResult> resultByRowId = new Map<Id, DNAMSIDPWrapper.SubmitResult>();
        for (AIReviewStageResult__c row : rows) {
            DNAMSIDPWrapper.SubmitRequest request = new DNAMSIDPWrapper.SubmitRequest();
            request.action = actionByName.get(row.IDPActionName__c);
            request.fileName = row.DocumentTitle__c;
            // remove(), not get(): the map must not keep a second reference to the file while it is sent (heap)
            request.fileBody = versionById.remove(Id.valueOf(row.ContentVersionId__c))?.VersionData;
            request.callbackUrl = DNAMSCallbackSignatureUtil.buildCallbackUrl(
                baseUrl,
                new Map<String, String>{
                    DNAMSPipelineConstants.PARAM_TOKEN => row.CallbackToken__c,
                    DNAMSPipelineConstants.PARAM_ACTION_ID => row.IDPActionId__c,
                    DNAMSPipelineConstants.PARAM_ACTION_VERSION => row.IDPActionVersion__c
                }
            );
            resultByRowId.put(row.Id, submit(client, request));
        }
        return resultByRowId;
    }

    /**
     * @description One POST; a missing action or file body fails locally without a callout.
     * @param client  IDP client
     * @param request Submit request
     * @return        Submit outcome
     **/
    private static DNAMSIDPWrapper.SubmitResult submit(IDocumentExtractionClient client, DNAMSIDPWrapper.SubmitRequest request) {
        if (request.action != null && request.fileBody != null) {
            // Callout to MuleSoft IDP (or the stub): create the execution
            return client.submitDocument(request);
        }
        DNAMSIDPWrapper.SubmitResult result = new DNAMSIDPWrapper.SubmitResult();
        result.isSuccess = false;
        result.errorMessage = request.action == null ? 'No active IDP action for this row.' : 'The file version has no content.';
        return result;
    }

    /**
     * @description Step [8]: success → In Progress with the execution id; failure → Error and a POST Error log.
     * @param row    Stage row (updated in memory)
     * @param result Submit outcome
     * @return       Error log to insert, or null on success
     **/
    private static AIReviewErrorLog__c applyResult(AIReviewStageResult__c row, DNAMSIDPWrapper.SubmitResult result) {
        row.MuleSoftExecutionStatus__c = result.executionStatus?.left(STATUS_LENGTH);
        if (result.isSuccess == true && String.isNotBlank(result.executionId)) {
            row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_IN_PROGRESS;
            row.MuleSoftExecutionId__c = result.executionId;
            row.SubmittedAt__c = System.now();
            return null;
        }
        String message = 'IDP submission failed' + (result.statusCode == null ? '' : ' (HTTP ' + result.statusCode + ')') + ': ' +
            (result.errorMessage ?? 'no execution id returned');
        row.ProcessingStatus__c = DNAMSPipelineConstants.ROW_ERROR;
        row.ProcessingErrorDetails__c = message.left(ERROR_LENGTH);
        row.ProcessingCompletedAt__c = System.now();
        DNAMSErrorLogHelper.LogDetail detail = rowLogDetail(row, DNAMSPipelineConstants.ERROR_POST, CLASS_NAME);
        detail.rawPayload = result.responseBody?.left(PAYLOAD_LENGTH);
        return DNAMSErrorLogHelper.buildLog(detail);
    }
}
