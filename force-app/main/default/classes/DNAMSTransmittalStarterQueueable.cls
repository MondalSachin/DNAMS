/**
 * @description     Rule validation step 23 (GREEN 100% -> transmittal drafting), enqueued by
 *                  DNAMSRuleValidationCompletionHelper: drafts the Ownership and Executive summaries automatically
 *                  (DNAMSTransmittalSummaryService, source Auto), then completes the run as Passed (package Review Passed). A failed draft
 *                  does not fail the run (the rules passed): TransmittalProcessingStatus__c is Failed and the RMR can
 *                  draft with the Draft AI Transmittal button. A run that is no longer Running is left alone (lockRun
 *                  settles a pending cancellation).
 *                  Changes Only runs: when DNAMSRunChangeDetector.summaryNeeded is false, the baseline's transmittal
 *                  drafting Completed and the package still has both summaries, the summaries are kept (no model call):
 *                  the baseline's latest Completed summary rows are copied into this run (ReusedFromResult__c), the run's
 *                  TransmittalProcessingStatus__c is Completed (the Draft button offers a redraft as usual) and the run
 *                  completes as Passed.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Changes Only runs keep unchanged transmittal summaries
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 * 1.1   2026-11-05   Abhishek Dutta  Automatic transmittal drafting replaces the placeholder; crash finalizer
 * 1.2   2026-11-09   Abhishek Dutta  Completing the run Passed sets the package status to Review Passed
 * 1.3   2026-11-10   Abhishek Dutta  Changes Only runs keep unchanged transmittal summaries
 **/
// Exception to guideline: without sharing because the system pipeline completes the run regardless of ownership
public without sharing class DNAMSTransmittalStarterQueueable implements Queueable, Database.AllowsCallouts {
    @TestVisible
    private static final String DRAFTED_REASON = 'Rule validation passed (GREEN). Transmittal summaries drafted automatically.';
    @TestVisible
    private static final String KEPT_REASON = 'Rule validation passed (GREEN). Transmittal summaries kept from ';
    @TestVisible
    private static final String DRAFT_FAILED_REASON = 'Rule validation passed (GREEN). Automatic transmittal drafting failed; the RMR can draft it with Draft AI Transmittal.';
    private static final String CLASS_NAME = DNAMSTransmittalStarterQueueable.class.getName();
    private static final Integer REASON_LENGTH = Schema.SObjectType.AI_Package_Review_Run__c.fields.Reason__c.getLength();

    private Id runId;

    /**
     * @description Creates the job for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMSTransmittalStarterQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Drafts the summaries (model calls before any DML), then completes the Running run as Passed.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (context != null) {
            System.attachFinalizer(new CrashFinalizer(runId));
        }
        try {
            if (DNAMS_PackageReviewPipelineService.lockRun(runId) == null) {
                return;
            }
            Id baselineRunId = DNAMSRunChangeDetector.baselineRunIdFor(runId);
            AI_Package_Review_Run__c baseline = baselineRunId == null ? null : keepableBaseline(runId, baselineRunId);
            if (baseline != null) {
                keepSummaries(runId, baseline);
                return;
            }
            DNAMSTransmittalSummaryService.DraftRequest request = new DNAMSTransmittalSummaryService.DraftRequest();
            request.runId = runId;
            request.draftSource = DNAMSPipelineConstants.DRAFT_SOURCE_AUTO;
            request.failingRuleCount = 0;
            request.requestedBy = UserInfo.getUserId();
            Boolean drafted = DNAMSTransmittalSummaryService.draft(request).success; // never throws; records its own failure
            if (baselineRunId != null) {
                DNAMSRunChangeDetector.appendChangeSummary(runId, DNAMSRunChangeDetector.SUMMARY_TRANSMITTAL,
                    drafted ? 'drafted again (results changed)' : 'drafting again failed');
            }
            completeRun(runId, drafted ? DRAFTED_REASON : DRAFT_FAILED_REASON);
        } catch (Exception e) {
            recordCrash(runId, e);
        }
    }

    /**
     * @description Changes Only: the baseline whose summaries can be kept, or null when they must be drafted again
     *              (something re-ran or a verdict changed, the baseline's drafting did not complete, or a summary is blank).
     * @param runId         The run
     * @param baselineRunId Its baseline
     * @return              The baseline run (Id, Name), or null
     **/
    private static AI_Package_Review_Run__c keepableBaseline(Id runId, Id baselineRunId) {
        if (DNAMSRunChangeDetector.summaryNeeded(runId)) {
            return null;
        }
        AI_Package_Review_Run__c baseline = [
            SELECT Id, Name, TransmittalProcessingStatus__c, Package__r.Ownership_Summary__c, Package__r.Executive_Summary__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :baselineRunId
            WITH SYSTEM_MODE
        ];
        Boolean hasSummaries = String.isNotBlank(baseline.Package__r?.Ownership_Summary__c) && String.isNotBlank(baseline.Package__r?.Executive_Summary__c);
        return baseline.TransmittalProcessingStatus__c == DNAMSPipelineConstants.RUN_STAGE_COMPLETED && hasSummaries ? baseline : null;
    }

    /**
     * @description Keeps the package summaries: copies the baseline's latest Completed row per summary type into this
     *              run, marks transmittal drafting Completed, records it in ChangeSummary__c and completes the run Passed.
     * @param runId    The run
     * @param baseline The baseline run (Id, Name)
     **/
    private static void keepSummaries(Id runId, AI_Package_Review_Run__c baseline) {
        Map<String, AIReviewStageResult__c> latestByType = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : DNAMSRunChangeDetector.stageRows(baseline.Id, DNAMSPipelineConstants.STAGE_TRANSMITTAL)) {
            if (row.ProcessingStatus__c == DNAMSPipelineConstants.ROW_COMPLETED && String.isNotBlank(row.SummaryType__c)) {
                latestByType.put(row.SummaryType__c, row); // rows come oldest first, so the last one wins
            }
        }
        Savepoint savepoint = Database.setSavepoint();
        try {
            Database.insert(DNAMSRunChangeDetector.cloneForReuse(latestByType.values(), runId), true, AccessLevel.SYSTEM_MODE);
            Database.update(
                new AI_Package_Review_Run__c(Id = runId, TransmittalProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_COMPLETED),
                true,
                AccessLevel.SYSTEM_MODE
            );
            DNAMSRunChangeDetector.appendChangeSummary(runId, DNAMSRunChangeDetector.SUMMARY_TRANSMITTAL, 'kept from ' + baseline.Name + ' (nothing changed)');
            completeRun(runId, KEPT_REASON + baseline.Name + ' (nothing changed).');
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e; // execute records the crash (transmittal Failed, run Passed)
        }
    }

    /**
     * @description Completes a still Running run as Passed, appends the reason and moves the package to Review Passed.
     * @param runId  The run
     * @param reason Text appended to Reason__c
     **/
    private static void completeRun(Id runId, String reason) {
        AI_Package_Review_Run__c run = DNAMS_PackageReviewPipelineService.lockRun(runId);
        if (run == null) {
            return;
        }
        String previous = [SELECT Reason__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE].Reason__c;
        run.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
        run.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_PASSED;
        run.Ended_At__c = System.now();
        run.Reason__c = ((String.isBlank(previous) ? '' : previous + '\n') + reason).left(REASON_LENGTH);
        Database.update(run, true, AccessLevel.SYSTEM_MODE);
        Database.update(
            new DNAMS_Package__c(Id = run.Package__c, Status__c = DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED),
            true,
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * @description Records a crash of this job: transmittal Failed, the run still completes as Passed (the rules
     *              passed) and a Processing Error log. Never throws.
     * @param runId The run
     * @param error The exception
     **/
    @SuppressWarnings('PMD.AvoidDebugStatements') // last resort when even the failure record cannot be saved
    private static void recordCrash(Id runId, Exception error) {
        try {
            Database.update(new AI_Package_Review_Run__c(Id = runId, TransmittalProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_FAILED), true, AccessLevel.SYSTEM_MODE);
            completeRun(runId, DRAFT_FAILED_REASON);
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = runId;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.stage = DNAMSPipelineConstants.STAGE_TRANSMITTAL;
            detail.severity = DNAMSPipelineConstants.SEVERITY_ERROR;
            detail.sourceClass = CLASS_NAME;
            detail.message = error.getTypeName() + ': ' + error.getMessage() + '\n' + error.getStackTraceString();
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
        } catch (Exception ignored) {
            System.debug(LoggingLevel.ERROR, 'Transmittal crash could not be recorded: ' + ignored.getMessage());
        }
    }

    /**
     * @description Finalizer: an unhandled exception (e.g. a limit) still ends the run Passed with transmittal Failed.
     **/
    public class CrashFinalizer implements Finalizer {
        private Id runId;

        /**
         * @description Creates the finalizer.
         * @param runId The run
         **/
        public CrashFinalizer(Id runId) {
            this.runId = runId;
        }

        /**
         * @description Records the crash after an unhandled exception; does nothing after success.
         * @param context Finalizer context
         **/
        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                recordCrash(runId, context.getException());
            }
        }
    }
}
