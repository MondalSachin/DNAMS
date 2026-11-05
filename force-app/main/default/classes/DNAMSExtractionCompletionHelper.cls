/**
 * @description     Completes the Extraction stage of DNAMS review runs (Lucid LLD page 5, steps 16 and 18-26).
 *                  For each Running run whose stage rows have all settled: validates every Completed row against
 *                  its IDP action's expected structure, then either fails the run (elements, package Health Red,
 *                  Issue Summary, narrative + RMR email, Admin Team email) or stores the consolidated extraction JSON
 *                  and starts rule validation. Runs still waiting on IDP are left untouched.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details A run whose extraction is already settled is not completed (or dispatched) twice
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-05   Abhishek Dutta  A run whose extraction is already settled is not completed (or dispatched) twice
 **/
public inherited sharing class DNAMSExtractionCompletionHelper {
    private static final String SOURCE_CLASS = DNAMSExtractionCompletionHelper.class.getName();
    private static final Integer NARRATIVE_LENGTH = 255;
    private static final Integer SUMMARY_LENGTH = 32768;
    private static final Integer REASON_LENGTH = 200;
    private static final Set<String> IN_FLIGHT_STATUSES = new Set<String>{
        DNAMSPipelineConstants.ROW_PENDING,
        DNAMSPipelineConstants.ROW_IN_PROGRESS
    };
    // Runs whose extraction stage is already settled are never completed again (parallel callbacks / batch finish)
    private static final Set<String> ALREADY_SETTLED = new Set<String>{
        DNAMSPipelineConstants.RUN_STAGE_COMPLETED,
        DNAMSPipelineConstants.RUN_STAGE_FAILED
    };
    // Issue label and payload-free reason per failed row status; any other status falls back to the row status.
    private static final Map<String, String> LABEL_BY_STATUS = new Map<String, String>{
        DNAMSPipelineConstants.ROW_TIMEOUT => DNAMSPipelineConstants.ERROR_TIMEOUT
    };
    private static final Map<String, String> REASON_BY_STATUS = new Map<String, String>{
        DNAMSPipelineConstants.ROW_TIMEOUT => 'No extraction result was received in time.'
    };
    private static final String DEFAULT_REASON = 'The extraction service could not process the document.';
    private static final String ADMIN_MESSAGE =
        'The document extraction for this package did not complete cleanly, so the AI review needs attention.';

    /** Test hook: expected structure JSON keyed by IDP action DeveloperName, used instead of the action metadata. */
    @TestVisible
    private static Map<String, String> expectedStructureOverride = new Map<String, String>();

    /**
     * @description Completes extraction for every given run that is Running and has no Pending or In Progress rows.
     * @param runIds AI_Package_Review_Run__c Ids
     * @example
     *   DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ runId });
     **/
    public static void completeExtraction(Set<Id> runIds) {
        if (runIds == null || runIds.isEmpty()) {
            return;
        }
        Savepoint savepointObj = Database.setSavepoint();
        try {
            List<RunState> states = loadSettledRuns(runIds);
            PendingChanges changes = new PendingChanges();
            for (RunState state : states) {
                evaluateRows(state, changes);
                applyOutcome(state, changes);
            }
            saveChanges(changes);
            dispatch(states);
        } catch (Exception e) {
            Database.rollback(savepointObj);
            // shortcut: a crash across several runs is logged without a run, so those runs are not failed; callers pass one run today.
            DNAMSErrorLogHelper.logException(e, runIds.size() == 1 ? new List<Id>(runIds)[0] : null, SOURCE_CLASS);
        }
    }

    // ------------------------------------------------------------------ Loading

    /**
     * @description Locks the Running runs and loads their stage rows; drops runs that still have rows in flight.
     * @param runIds Requested run Ids
     * @return One state per run that is ready to complete
     **/
    private static List<RunState> loadSettledRuns(Set<Id> runIds) {
        Map<Id, RunState> stateByRunId = lockRuns(runIds);
        Set<Id> inFlightRunIds = new Set<Id>();
        for (AIReviewStageResult__c row : [
            SELECT
                Id, ReviewRun__c, PackageElement__c, ElementType__c, DocumentType__c, DocumentTitle__c,
                ContentVersionId__c, IDPActionName__c, ProcessingStatus__c, RawStageResponseJSON__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c IN :stateByRunId.keySet() AND Stage__c = :DNAMSPipelineConstants.STAGE_EXTRACTION
            WITH SYSTEM_MODE
            ORDER BY ElementType__c, DocumentTitle__c
        ]) {
            stateByRunId.get(row.ReviewRun__c).rows.add(row);
            if (IN_FLIGHT_STATUSES.contains(row.ProcessingStatus__c)) {
                inFlightRunIds.add(row.ReviewRun__c);
            }
        }
        for (Id runId : inFlightRunIds) {
            stateByRunId.remove(runId);
        }
        return stateByRunId.values();
    }

    /**
     * @description Locks the runs FOR UPDATE (serialising parallel callbacks); a Cancelling run is settled as Cancelled.
     * @param runIds Requested run Ids
     * @return State per Running run
     **/
    private static Map<Id, RunState> lockRuns(Set<Id> runIds) {
        Map<Id, RunState> stateByRunId = new Map<Id, RunState>();
        List<AI_Package_Review_Run__c> cancelled = new List<AI_Package_Review_Run__c>();
        for (AI_Package_Review_Run__c run : [
            SELECT Id, Package__c, Status__c
            FROM AI_Package_Review_Run__c
            WHERE Id IN :runIds
                AND Status__c IN :DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES
                AND ExtractionProcessingStatus__c NOT IN :ALREADY_SETTLED
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            if (run.Status__c == DNAMS_PackageReviewPipelineService.RUN_RUNNING) {
                RunState state = new RunState();
                state.run = run;
                stateByRunId.put(run.Id, state);
                continue;
            }
            run.Status__c = DNAMS_PackageReviewPipelineService.RUN_CANCELLED;
            run.Ended_At__c = System.now();
            cancelled.add(run);
        }
        Database.update(cancelled, true, AccessLevel.SYSTEM_MODE);
        return stateByRunId;
    }

    // ------------------------------------------------------------------ Evaluation (steps 18, 20, 22)

    /**
     * @description Validates Completed rows and records an issue for every Error or Timeout row.
     * @param state   The run being completed
     * @param changes Collected DML
     **/
    private static void evaluateRows(RunState state, PendingChanges changes) {
        for (AIReviewStageResult__c row : state.rows) {
            String status = row.ProcessingStatus__c;
            if (status == DNAMSPipelineConstants.ROW_COMPLETED) {
                validateRow(state, row, changes);
            } else {
                state.addIssue(row, LABEL_BY_STATUS.get(status) ?? status, REASON_BY_STATUS.get(status) ?? DEFAULT_REASON);
            }
        }
    }

    /**
     * @description Checks one Completed row's normalized output against the expected structure of its IDP action.
     *              A mismatch (or an unreadable result) marks the row Failed, adds an issue and a Schema Mismatch log.
     * @param state   The run being completed
     * @param row     A Completed stage row
     * @param changes Collected DML
     **/
    private static void validateRow(RunState state, AIReviewStageResult__c row, PendingChanges changes) {
        state.hasValidatedRows = true;
        DNAMSErrorLogHelper.LogDetail detail = schemaMismatchDetail(row);
        try {
            DNAMSIDPWrapper.NormalizedOutput output = DNAMSIDPWrapper.normalizeOutput(row.RawStageResponseJSON__c);
            DNAMSStructureValidationUtil.ValidationResult result = DNAMSStructureValidationUtil.validate(
                expectedStructure(row.IDPActionName__c),
                output
            );
            if (result.isValid == true) {
                changes.rows.add(new AIReviewStageResult__c(Id = row.Id, SchemaValidationStatus__c = DNAMSPipelineConstants.SCHEMA_PASSED));
                state.addExtraction(row, output.toMap());
                return;
            }
            detail.missingFields = joinKeys(result.missingKeys);
            detail.unexpectedFields = joinKeys(result.unexpectedKeys);
        } catch (Exception e) {
            // Exception to guideline: an unreadable result or missing action is logged as this document's Schema Mismatch, not a run crash.
            detail.message = 'The extraction result could not be checked: ' + e.getMessage();
        }
        changes.rows.add(new AIReviewStageResult__c(Id = row.Id, SchemaValidationStatus__c = DNAMSPipelineConstants.SCHEMA_FAILED));
        changes.logs.add(DNAMSErrorLogHelper.buildLog(detail));
        state.hasSchemaFailure = true;
        state.addIssue(
            row,
            DNAMSPipelineConstants.ERROR_SCHEMA_MISMATCH,
            ('Missing fields: ' + (detail.missingFields ?? 'unknown') + '; unexpected fields: ' + (detail.unexpectedFields ?? 'unknown'))
                .left(REASON_LENGTH)
        );
    }

    /**
     * @description Expected structure JSON of an IDP action: the test override first, then the action metadata.
     * @param actionName DNAMSIDPAction__mdt DeveloperName
     * @return The expected structure JSON
     * @throws DNAMSPipelineException when no active action with an expected structure exists
     **/
    private static String expectedStructure(String actionName) {
        String expected = expectedStructureOverride.containsKey(actionName)
            ? expectedStructureOverride.get(actionName)
            : DNAMSIDPActionUtil.getActionByName(actionName)?.expectedStructure;
        if (String.isBlank(expected)) {
            throw new DNAMSPipelineException('No active IDP action with an expected structure is configured for "' + actionName + '".');
        }
        return expected;
    }

    /**
     * @description Starts the Schema Mismatch error log detail for a row; the caller adds the field lists or the reason.
     * @param row The row being checked
     * @return The log detail
     **/
    private static DNAMSErrorLogHelper.LogDetail schemaMismatchDetail(AIReviewStageResult__c row) {
        DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
        detail.runId = row.ReviewRun__c;
        detail.elementId = row.PackageElement__c;
        detail.stageResultId = row.Id;
        detail.errorType = DNAMSPipelineConstants.ERROR_SCHEMA_MISMATCH;
        detail.sourceClass = SOURCE_CLASS;
        detail.documentTitle = row.DocumentTitle__c;
        detail.documentType = row.DocumentType__c;
        detail.message = 'The extraction result does not match the expected structure of IDP action ' + row.IDPActionName__c + '.';
        return detail;
    }

    /**
     * @description Joins key names with commas.
     * @param keys Key names, or null
     * @return The joined names (blank when there are none)
     **/
    private static String joinKeys(List<String> keys) {
        return String.join(keys ?? new List<String>(), ', ');
    }

    // ------------------------------------------------------------------ Outcome (steps 18, 23, 26)

    /**
     * @description Collects element, package and run updates for a failed or passed run.
     * @param state   The evaluated run
     * @param changes Collected DML
     **/
    private static void applyOutcome(RunState state, PendingChanges changes) {
        changes.elements.addAll(state.elementUpdates());
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Id = state.run.Id);
        changes.runs.add(run);
        if (state.issues.isEmpty()) {
            run.ConsolidatedExtractionJSON__c = JSON.serialize(state.extractionsByAction);
            run.ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED;
            run.ExtractionSchemaValidation__c = DNAMSPipelineConstants.SCHEMA_PASSED;
            return;
        }
        changes.packages.add(new DNAMS_Package__c(Id = state.run.Package__c, Health__c = 'Red'));
        run.ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_FAILED;
        // Failed on any mismatch; Passed when every checked row matched; blank when no row reached the check.
        run.ExtractionSchemaValidation__c = state.hasSchemaFailure
            ? DNAMSPipelineConstants.SCHEMA_FAILED
            : (state.hasValidatedRows ? DNAMSPipelineConstants.SCHEMA_PASSED : null);
        run.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW;
        run.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
        run.Ended_At__c = System.now();
        run.Issue_Summary__c = String.join(state.issues, '\n').left(SUMMARY_LENGTH);
    }

    /**
     * @description Writes the collected changes, one DML per object type; any failure rolls the completion back.
     * @param changes Collected DML
     **/
    private static void saveChanges(PendingChanges changes) {
        Database.update(changes.rows, true, AccessLevel.SYSTEM_MODE);
        Database.update(changes.elements, true, AccessLevel.SYSTEM_MODE);
        Database.update(changes.packages, true, AccessLevel.SYSTEM_MODE);
        Database.update(changes.runs, true, AccessLevel.SYSTEM_MODE);
        DNAMSErrorLogHelper.insertLogs(changes.logs);
    }

    // ------------------------------------------------------------------ Hand-off (steps 19, 24, 26)

    /**
     * @description Queues the next job per run (narrative for a failed run, rule validation for a passed run) within
     *              the queueable limit, logging any run that could not be queued, then emails the Admin Team.
     * @param states The completed runs
     **/
    @SuppressWarnings('PMD.OperationWithLimitsInLoop') // one job per run by contract, guarded by Limits.getQueueableJobs()
    private static void dispatch(List<RunState> states) {
        List<AIReviewErrorLog__c> skippedLogs = new List<AIReviewErrorLog__c>();
        Set<Id> failedRunIds = new Set<Id>();
        for (RunState state : states) {
            Boolean isFailed = !state.issues.isEmpty();
            if (isFailed) {
                failedRunIds.add(state.run.Id);
            }
            Queueable nextJob = isFailed
                ? (Queueable) new DNAMS_PackageNarrativeQueueable(state.run.Id)
                : (Queueable) new DNAMSRuleValidationStarterQueueable(state.run.Id);
            String notQueuedReason = new JobQueue().tryEnqueue(nextJob);
            if (notQueuedReason == null) {
                continue;
            }
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = state.run.Id;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.sourceClass = SOURCE_CLASS;
            detail.message = 'The next job for this run was not queued (' + notQueuedReason + '). The run result stands; re-run to retry.';
            skippedLogs.add(DNAMSErrorLogHelper.buildLog(detail));
        }
        DNAMSErrorLogHelper.insertLogs(skippedLogs);
        DNAMSNotificationHelper.notifyAdminTeam(adminBodies(failedRunIds));
    }

    /**
     * @description Queues follow-up jobs without letting a refused enqueue undo the run's result.
     **/
    private class JobQueue {
        /**
         * @description Queues the job when the platform allows it.
         * @param job Queueable to enqueue
         * @return    Null when queued, otherwise why it was not
         **/
        private String tryEnqueue(Queueable job) {
            if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
                return 'queueable job limit reached';
            }
            try {
                System.enqueueJob(job);
                return null;
            } catch (AsyncException asyncError) {
                // Handled: e.g. the async chain depth limit; logged by the caller and the run keeps its outcome
                return asyncError.getMessage();
            }
        }
    }

    /**
     * @description Generic Admin Team message per failed run, listing the run's error log names (no payloads).
     * @param failedRunIds Failed run Ids
     * @return Message keyed by run Id (empty when no run failed)
     **/
    private static Map<Id, String> adminBodies(Set<Id> failedRunIds) {
        Map<Id, List<String>> logNamesByRunId = new Map<Id, List<String>>();
        for (Id runId : failedRunIds) {
            logNamesByRunId.put(runId, new List<String>());
        }
        for (AIReviewErrorLog__c log : [
            SELECT Name, ReviewRun__c
            FROM AIReviewErrorLog__c
            WHERE ReviewRun__c IN :failedRunIds
            WITH SYSTEM_MODE
            ORDER BY Name
            LIMIT 1000
        ]) {
            logNamesByRunId.get(log.ReviewRun__c).add(log.Name);
        }
        Map<Id, String> bodyByRunId = new Map<Id, String>();
        for (Id runId : logNamesByRunId.keySet()) {
            bodyByRunId.put(runId, ADMIN_MESSAGE + '\n\nError logs: ' + joinKeys(logNamesByRunId.get(runId)));
        }
        return bodyByRunId;
    }

    // ------------------------------------------------------------------ Wrappers

    /**
     * @description Per-run state collected while completing extraction.
     **/
    private class RunState {
        AI_Package_Review_Run__c run;
        List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        Boolean hasValidatedRows = false;
        Boolean hasSchemaFailure = false;
        List<String> issues = new List<String>();
        Map<Id, List<String>> issuesByElementId = new Map<Id, List<String>>();
        Map<String, List<Object>> extractionsByAction = new Map<String, List<Object>>();

        /**
         * @description Records a problem document for the Issue Summary and its element's narrative.
         * @param row       The problem row
         * @param errorType Short label shown in brackets
         * @param reason    Short, payload-free reason
         **/
        void addIssue(AIReviewStageResult__c row, String errorType, String reason) {
            String title = row.DocumentTitle__c ?? 'Untitled document';
            issues.add('- ' + row.ElementType__c + ' / ' + title + ' [' + errorType + ']: ' + reason);
            if (!issuesByElementId.containsKey(row.PackageElement__c)) {
                issuesByElementId.put(row.PackageElement__c, new List<String>());
            }
            issuesByElementId.get(row.PackageElement__c).add(title + ': ' + reason);
        }

        /**
         * @description Adds a valid document to the consolidated extraction, grouped by IDP action.
         * @param row  The valid row
         * @param data The normalized output map
         **/
        void addExtraction(AIReviewStageResult__c row, Map<String, Object> data) {
            if (!extractionsByAction.containsKey(row.IDPActionName__c)) {
                extractionsByAction.put(row.IDPActionName__c, new List<Object>());
            }
            extractionsByAction.get(row.IDPActionName__c)
                .add(
                    new Map<String, Object>{
                        'contentVersionId' => row.ContentVersionId__c,
                        'documentTitle' => row.DocumentTitle__c,
                        'elementType' => row.ElementType__c,
                        'data' => data
                    }
                );
        }

        /**
         * @description Extraction status per element that had rows: Failed with a narrative when any of its
         *              documents failed, else Passed.
         * @return Element updates
         **/
        List<DNAMS_Package_Element__c> elementUpdates() {
            Map<Id, DNAMS_Package_Element__c> updatesById = new Map<Id, DNAMS_Package_Element__c>();
            for (AIReviewStageResult__c row : rows) {
                updatesById.put(
                    row.PackageElement__c,
                    new DNAMS_Package_Element__c(Id = row.PackageElement__c, Extraction_Status__c = DNAMS_PackageReviewPipelineService.STAGE_PASSED)
                );
            }
            updatesById.remove(null);
            for (Id elementId : updatesById.keySet()) {
                List<String> elementIssues = issuesByElementId.get(elementId);
                if (elementIssues != null) {
                    updatesById.get(elementId).Extraction_Status__c = DNAMS_PackageReviewPipelineService.STAGE_FAILED;
                    updatesById.get(elementId).Element_Narrative__c = ('Extraction failed. ' + String.join(elementIssues, '; ')).left(NARRATIVE_LENGTH);
                }
            }
            return updatesById.values();
        }
    }

    /**
     * @description DML collected across runs, written once per object type by saveChanges.
     **/
    private class PendingChanges {
        List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        List<DNAMS_Package_Element__c> elements = new List<DNAMS_Package_Element__c>();
        List<DNAMS_Package__c> packages = new List<DNAMS_Package__c>();
        List<AI_Package_Review_Run__c> runs = new List<AI_Package_Review_Run__c>();
        List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
    }
}
