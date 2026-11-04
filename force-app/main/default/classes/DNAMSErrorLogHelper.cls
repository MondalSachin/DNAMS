/**
 * @description     Central builder and writer for AIReviewErrorLog__c records of the DNAMS AI review pipeline.
 *                  Callers build logs in bulk with buildLog and insert them once with insertLogs; unexpected
 *                  exceptions go through logException, which also fails the run's extraction stage.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSErrorLogHelper {
    private static final Integer TEXT_LENGTH = 255;
    private static final Integer LONG_TEXT_LENGTH = 32768;
    private static final Integer PAYLOAD_LENGTH = 131072;

    /**
     * @description Values for one error log. All fields are optional; text is truncated to the field length.
     **/
    public class LogDetail {
        public Id runId;
        public Id elementId;
        public Id stageResultId;
        public String errorType;
        public String sourceClass;
        public String message;
        public String documentTitle;
        public String documentType;
        public String missingFields;
        public String unexpectedFields;
        public String rawPayload;
        public String stage;
        public String severity;
    }

    /**
     * @description Builds an error log (Severity Error; stage from detail.stage, Extraction by default) without inserting it.
     * @param detail Values for the log
     * @return The unsaved AIReviewErrorLog__c record
     * @example
     *   logs.add(DNAMSErrorLogHelper.buildLog(detail));
     **/
    public static AIReviewErrorLog__c buildLog(LogDetail detail) {
        return new AIReviewErrorLog__c(
            ReviewRun__c = detail.runId,
            PackageElement__c = detail.elementId,
            StageResult__c = detail.stageResultId,
            Stage__c = detail.stage ?? DNAMSPipelineConstants.STAGE_EXTRACTION,
            ErrorType__c = detail.errorType,
            Severity__c = detail.severity ?? DNAMSPipelineConstants.SEVERITY_ERROR,
            SourceClass__c = detail.sourceClass?.left(TEXT_LENGTH),
            DocumentTitle__c = detail.documentTitle?.left(TEXT_LENGTH),
            DocumentType__c = detail.documentType?.left(TEXT_LENGTH),
            Message__c = detail.message?.left(LONG_TEXT_LENGTH),
            MissingFields__c = detail.missingFields?.left(LONG_TEXT_LENGTH),
            UnexpectedFields__c = detail.unexpectedFields?.left(LONG_TEXT_LENGTH),
            RawPayload__c = detail.rawPayload?.left(PAYLOAD_LENGTH)
        );
    }

    /**
     * @description Inserts the logs with partial success, so one bad log never blocks the others.
     * @param logs Logs built with buildLog
     **/
    public static void insertLogs(List<AIReviewErrorLog__c> logs) {
        if (logs == null || logs.isEmpty()) {
            return;
        }
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);
    }

    /**
     * @description Logs an unexpected exception as a Processing Error and, when a run is given, fails the run's
     *              extraction stage. Never throws, so it is safe to call from any catch block.
     * @param caughtError The exception caught
     * @param runId       The review run being processed, or null
     * @param sourceClass Name of the class that caught the exception
     * @example
     *   DNAMSErrorLogHelper.logException(e, runId, DNAMSExtractionSubmitBatch.class.getName());
     **/
    @SuppressWarnings('PMD.AvoidDebugStatements') // the logger's own failure has nowhere else to go
    public static void logException(Exception caughtError, Id runId, String sourceClass) {
        try {
            LogDetail detail = new LogDetail();
            detail.runId = runId;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.sourceClass = sourceClass;
            detail.message = describe(caughtError);
            insertLogs(new List<AIReviewErrorLog__c>{ buildLog(detail) });
            if (runId != null) {
                DNAMS_PackageReviewPipelineService.failRun(runId, AI_Package_Review_Run__c.ExtractionProcessingStatus__c, caughtError);
            }
        } catch (Exception loggingError) {
            // Exception to guideline: the logger is the last resort, so a failure here can only go to the debug log.
            System.debug(LoggingLevel.ERROR, 'DNAMSErrorLogHelper could not log: ' + describe(loggingError));
        }
    }

    /**
     * @description Formats an exception as type, message and stack trace.
     * @param error The exception, or null
     * @return The formatted text
     **/
    private static String describe(Exception error) {
        if (error == null) {
            return 'Unknown error (no exception supplied).';
        }
        return error.getTypeName() + ': ' + error.getMessage() + '\n' + error.getStackTraceString();
    }
}
