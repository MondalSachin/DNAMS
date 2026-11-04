/**
 * @description     Shared constants for the DNAMS AI review pipeline extraction stage (statuses, event types, error types).
 *                  Classification-stage constants stay in DNAMS_PackageReviewPipelineService.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSPipelineConstants {
    // Stage names (AIReviewStageResult__c.Stage__c, AIReviewErrorLog__c.Stage__c, element Current_Stage__c)
    public static final String STAGE_EXTRACTION = 'Extraction';

    // AIReviewStageResult__c.ProcessingStatus__c
    public static final String ROW_PENDING = 'Pending';
    public static final String ROW_IN_PROGRESS = 'In Progress';
    public static final String ROW_COMPLETED = 'Completed';
    public static final String ROW_ERROR = 'Error';
    public static final String ROW_TIMEOUT = 'Failed (Timeout)';

    // AI_Package_Review_Run__c.ExtractionProcessingStatus__c
    public static final String RUN_STAGE_PENDING = 'Pending';
    public static final String RUN_STAGE_IN_PROGRESS = 'In Progress';
    public static final String RUN_STAGE_COMPLETED = 'Completed';
    public static final String RUN_STAGE_FAILED = 'Failed';

    // Structure validation (row SchemaValidationStatus__c, run ExtractionSchemaValidation__c)
    public static final String SCHEMA_PASSED = 'Passed';
    public static final String SCHEMA_FAILED = 'Failed';

    // DNAMS_Package_Element__c.Extraction_Status__c value for files whose document type has no IDP mapping
    public static final String ELEMENT_NOT_APPLICABLE = 'Not Applicable';

    // DNAMSIDPEvent__e.EventType__c
    public static final String EVENT_START_EXTRACTION = 'Start Extraction';
    public static final String EVENT_CALLBACK = 'Callback';

    // AIReviewErrorLog__c.ErrorType__c and Severity__c
    public static final String ERROR_POST = 'POST Error';
    public static final String ERROR_IDP_FAILURE = 'IDP Failure';
    public static final String ERROR_TIMEOUT = 'Timeout';
    public static final String ERROR_SCHEMA_MISMATCH = 'Schema Mismatch';
    public static final String ERROR_PROCESSING = 'Processing Error';
    public static final String ERROR_FILE_TOO_LARGE = 'File Too Large';
    public static final String ERROR_INVALID_FILE_TYPE = 'Invalid File Type';

    // Pre-flight file gate fallbacks when DNAMS_Pipeline_Setting__mdt leaves MaxFileSizeMB__c / AllowedFileExtensions__c blank
    public static final Decimal DEFAULT_MAX_FILE_SIZE_MB = 3;
    public static final String DEFAULT_ALLOWED_EXTENSIONS = 'pdf';
    public static final String SEVERITY_ERROR = 'Error';
    public static final String SEVERITY_WARNING = 'Warning';

    // DNAMS_Pipeline_Setting__mdt.IDPMode__c
    public static final String IDP_MODE_STUB = 'Stub';
    public static final String IDP_MODE_LIVE = 'Live';

    // MuleSoft IDP execution statuses
    public static final String IDP_SUCCEEDED = 'SUCCEEDED';
    public static final Set<String> IDP_FAILED_STATUSES = new Set<String>{ 'FAILED', 'DISMISSED', 'MANUAL_VALIDATION_REQUIRED', 'PARTIAL_SUCCESS' };
    public static final Set<String> IDP_PENDING_STATUSES = new Set<String>{ 'ACKNOWLEDGED', 'IN_PROGRESS', 'RESULTS_PENDING' };

    // Callback query parameter names and REST path (see DNAMSIDPCallbackAPI)
    public static final String PARAM_TOKEN = 't';
    public static final String PARAM_ACTION_ID = 'a';
    public static final String PARAM_ACTION_VERSION = 'av';
    public static final String PARAM_SIGNATURE = 'sig';
    public static final String CALLBACK_PATH = '/services/apexrest/v1/receiveIdpCallback';
    // Order of the callback path segments after CALLBACK_PATH; the signature is the last segment
    public static final List<String> PATH_PARAM_ORDER = new List<String>{ PARAM_TOKEN, PARAM_ACTION_ID, PARAM_ACTION_VERSION };
    public static final String ERROR_CALLBACK_REJECTED = 'Callback Rejected';

    // Rule validation stage (AIReviewStageResult__c rows with Stage__c = STAGE_RULE_VALIDATION, one per rule)
    public static final String STAGE_RULE_VALIDATION = 'Rule Validation';
    public static final String STAGE_TRANSMITTAL = 'Transmittal Drafting';
    public static final String VERDICT_PASS = 'PASS';
    public static final String VERDICT_FAIL = 'FAIL';
    public static final String VERDICT_CANNOT_DECIDE = 'CANNOT_DECIDE';
    public static final String VERDICT_NOT_APPLICABLE = 'NOT_APPLICABLE';
    public static final String METHOD_EXACT = 'ExactMatch';
    public static final String METHOD_AI = 'AIMatch';
    public static final String METHOD_PIR = 'PIR';
    public static final String RULE_TYPE_COMPLETENESS = 'Completeness';
    public static final String APPLIED_TO_PACKAGE = 'Package';
    public static final String FIELD_TYPE_EXTRACTION = 'Extraction';
    public static final String FIELD_TYPE_RECORD = 'Record';
    public static final String FIELD_TYPE_STATIC = 'Static';
    public static final String PIR_RULE_ID = 'PIR';
    public static final String PIR_RULE_NAME = 'PIR Clearance';

    // RAG bands (Package Health__c) from the rule pass rate: 100% Green, >= 85% Amber, below Red
    public static final String HEALTH_GREEN = 'Green';
    public static final String HEALTH_AMBER = 'Amber';
    public static final String HEALTH_RED = 'Red';
    public static final Decimal GREEN_PASS_RATE = 100;
    public static final Decimal AMBER_PASS_RATE = 85;
    public static final Integer DEFAULT_RULE_BATCH_SIZE = 50;
}
