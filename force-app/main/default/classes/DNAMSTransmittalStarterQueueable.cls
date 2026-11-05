/**
 * @description     Rule validation step 23 (GREEN 100% -> transmittal drafting), enqueued by
 *                  DNAMSRuleValidationCompletionHelper: drafts the Ownership and Executive summaries automatically
 *                  (DNAMSTransmittalSummaryService, source Auto), then completes the run as Passed. A failed draft
 *                  does not fail the run (the rules passed): TransmittalProcessingStatus__c is Failed and the RMR can
 *                  draft with the Draft AI Transmittal button. A run that is no longer Running is left alone (lockRun
 *                  settles a pending cancellation).
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Automatic transmittal drafting replaces the placeholder
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 * 1.1   2026-11-05   Abhishek Dutta  Automatic transmittal drafting replaces the placeholder; crash finalizer
 **/
// Exception to guideline: without sharing because the system pipeline completes the run regardless of ownership
public without sharing class DNAMSTransmittalStarterQueueable implements Queueable, Database.AllowsCallouts {
    @TestVisible
    private static final String DRAFTED_REASON = 'Rule validation passed (GREEN). Transmittal summaries drafted automatically.';
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
            DNAMSTransmittalSummaryService.DraftRequest request = new DNAMSTransmittalSummaryService.DraftRequest();
            request.runId = runId;
            request.draftSource = DNAMSPipelineConstants.DRAFT_SOURCE_AUTO;
            request.failingRuleCount = 0;
            request.requestedBy = UserInfo.getUserId();
            Boolean drafted = DNAMSTransmittalSummaryService.draft(request).success; // never throws; records its own failure
            completeRun(runId, drafted ? DRAFTED_REASON : DRAFT_FAILED_REASON);
        } catch (Exception e) {
            recordCrash(runId, e);
        }
    }

    /**
     * @description Completes a still Running run as Passed and appends the reason.
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
