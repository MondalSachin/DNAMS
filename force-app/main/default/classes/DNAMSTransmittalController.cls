/**
 * @description     Backs the Draft AI Transmittal quick action (LWC dnamsDraftTransmittal) on DNAMS_Package__c: works out
 *                  whether the latest AI review run can be drafted and, after the RMR confirms, drafts the Ownership and
 *                  Executive summaries through DNAMSTransmittalSummaryService. The run and its rows are read in system mode
 *                  because the RMR may not own the run; access to the package itself is checked in user mode.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Abhishek Dutta  Initial version
 **/
public with sharing class DNAMSTransmittalController {
    // DraftState.scenario values (the LWC switches on these)
    public static final String SCENARIO_NO_RUN = 'NO_RUN';
    public static final String SCENARIO_IN_PROGRESS = 'IN_PROGRESS';
    public static final String SCENARIO_DRAFTING = 'DRAFTING';
    public static final String SCENARIO_DRAFTED = 'DRAFTED';
    public static final String SCENARIO_RULES_FAILED = 'RULES_FAILED';
    public static final String SCENARIO_READY = 'READY';

    public static final String MESSAGE_NO_RUN = 'No AI Document Review has run for this package yet.';
    public static final String MESSAGE_IN_PROGRESS = 'The AI Document Review is still in progress. Please retry in a while.';
    public static final String MESSAGE_DRAFTING = 'A transmittal is already being drafted for this package. Please try back in a minute.';
    public static final String MESSAGE_DRAFTED =
        'The transmittal has already been drafted for this run. Do you want to redraft the transmittal summaries?';
    public static final String MESSAGE_RULES_FAILED =
        'Some rules have failed for this package ({0} failing rule(s)). Please make sure you are aware of them and they have been ' +
        'reviewed thoroughly. Do you still want to draft the transmittal anyway?';
    public static final String MESSAGE_READY = 'Draft the transmittal summaries now?';
    public static final String MESSAGE_DRAFT_SUCCESS = 'The transmittal summaries have been drafted.';
    public static final String MESSAGE_NO_ACCESS = 'You do not have access to this package.';
    public static final String MESSAGE_UNEXPECTED = 'Something went wrong with the transmittal. Please try again or contact your administrator.';

    private static final String CLASS_NAME = DNAMSTransmittalController.class.getName();
    private static final Set<String> DRAFTING_STATUSES = new Set<String>{
        DNAMSPipelineConstants.RUN_STAGE_PENDING,
        DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS
    };
    // Only these scenarios may draft; each maps to the Transmittal Draft Source recorded on the package
    private static final Map<String, String> SOURCE_BY_SCENARIO = new Map<String, String>{
        SCENARIO_DRAFTED => DNAMSPipelineConstants.DRAFT_SOURCE_RMR_REDRAFT,
        SCENARIO_RULES_FAILED => DNAMSPipelineConstants.DRAFT_SOURCE_RMR_OVERRIDE,
        SCENARIO_READY => DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT
    };

    /**
     * @description What the Draft AI Transmittal action should show for a package.
     **/
    public class DraftState {
        @AuraEnabled
        public String scenario;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Integer failingRuleCount;
        @AuraEnabled
        public Id runId;
    }

    /**
     * @description Outcome of a drafting request.
     **/
    public class DraftOutcome {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
    }

    /**
     * @description Works out the drafting scenario for the package's latest (non-discarded) review run.
     * @param packageId DNAMS_Package__c id
     * @return The scenario, its message, the failing rule count and the run id
     * @example
     *   DNAMSTransmittalController.DraftState state = DNAMSTransmittalController.getDraftState(packageId);
     **/
    @AuraEnabled
    public static DraftState getDraftState(Id packageId) {
        assertPackageAccess(packageId);
        try {
            return evaluate(packageId);
        } catch (Exception e) {
            throw unexpectedError(e);
        }
    }

    /**
     * @description Re-evaluates the scenario and, when drafting is allowed, drafts both summaries synchronously
     *              (two prompt calls). Info-only scenarios return their message without drafting.
     * @param packageId DNAMS_Package__c id
     * @return success and a user-facing message
     * @example
     *   DNAMSTransmittalController.DraftOutcome outcome = DNAMSTransmittalController.draftTransmittal(packageId);
     **/
    @AuraEnabled
    public static DraftOutcome draftTransmittal(Id packageId) {
        assertPackageAccess(packageId);
        try {
            DraftState state = evaluate(packageId);
            DraftOutcome outcome = new DraftOutcome();
            if (!SOURCE_BY_SCENARIO.containsKey(state.scenario)) {
                outcome.success = false;
                outcome.message = state.message;
                return outcome;
            }
            DNAMSTransmittalSummaryService.DraftRequest request = new DNAMSTransmittalSummaryService.DraftRequest();
            request.runId = state.runId;
            request.draftSource = SOURCE_BY_SCENARIO.get(state.scenario);
            request.failingRuleCount = state.failingRuleCount;
            request.requestedBy = UserInfo.getUserId();
            DNAMSTransmittalSummaryService.DraftResult result = DNAMSTransmittalSummaryService.draft(request);
            outcome.success = result.success == true;
            outcome.message = outcome.success ? MESSAGE_DRAFT_SUCCESS : result.message;
            return outcome;
        } catch (Exception e) {
            throw unexpectedError(e);
        }
    }

    /**
     * @description Applies the scenario order: no run, review in progress, drafting, drafted, rules failed, ready.
     * @param packageId DNAMS_Package__c id
     * @return The draft state
     **/
    private static DraftState evaluate(Id packageId) {
        DraftState state = new DraftState();
        List<AI_Package_Review_Run__c> runs = [
            SELECT
                Id,
                Classification_Processing_Status__c,
                ExtractionProcessingStatus__c,
                RuleValidationProcessingStatus__c,
                TransmittalProcessingStatus__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c != :DNAMS_PackageReviewPipelineService.RUN_DISCARDED
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            return withScenario(state, SCENARIO_NO_RUN, MESSAGE_NO_RUN);
        }
        AI_Package_Review_Run__c run = runs[0];
        state.runId = run.Id;
        // Every stage must be Completed; this also covers a Running/Cancelling run whose rule validation is not done.
        if (!isCompleted(run.Classification_Processing_Status__c) || !isCompleted(run.ExtractionProcessingStatus__c) ||
            !isCompleted(run.RuleValidationProcessingStatus__c)) {
            return withScenario(state, SCENARIO_IN_PROGRESS, MESSAGE_IN_PROGRESS);
        }
        if (DRAFTING_STATUSES.contains(run.TransmittalProcessingStatus__c)) {
            return withScenario(state, SCENARIO_DRAFTING, MESSAGE_DRAFTING);
        }
        state.failingRuleCount = DNAMSTransmittalSummaryService.failingRuleCount(run.Id);
        if (isCompleted(run.TransmittalProcessingStatus__c)) {
            return withScenario(state, SCENARIO_DRAFTED, MESSAGE_DRAFTED);
        }
        if (state.failingRuleCount > 0) {
            return withScenario(state, SCENARIO_RULES_FAILED, String.format(MESSAGE_RULES_FAILED, new List<Object>{ state.failingRuleCount }));
        }
        return withScenario(state, SCENARIO_READY, MESSAGE_READY);
    }

    /**
     * @description Sets the scenario and message on a state.
     * @param state    The state to update
     * @param scenario One of the SCENARIO_* values
     * @param message  The message shown to the RMR
     * @return The same state
     **/
    private static DraftState withScenario(DraftState state, String scenario, String message) {
        state.scenario = scenario;
        state.message = message;
        return state;
    }

    /**
     * @description Whether a run stage status is Completed.
     * @param status The stage processing status
     * @return true when Completed
     **/
    private static Boolean isCompleted(String status) {
        return status == DNAMSPipelineConstants.RUN_STAGE_COMPLETED;
    }

    /**
     * @description Throws when the running user cannot read the package (sharing and object access in user mode),
     *              because the run and the drafting service work in system mode.
     * @param packageId DNAMS_Package__c id
     **/
    private static void assertPackageAccess(Id packageId) {
        if (packageId == null || [SELECT Id FROM DNAMS_Package__c WHERE Id = :packageId WITH USER_MODE LIMIT 1].isEmpty()) {
            throw auraError(MESSAGE_NO_ACCESS);
        }
    }

    /**
     * @description Logs an unexpected error and returns a user-safe AuraHandledException.
     * @param caughtError The exception caught
     * @return The exception to throw
     **/
    private static AuraHandledException unexpectedError(Exception caughtError) {
        DNAMSErrorLogHelper.logException(caughtError, null, CLASS_NAME);
        return auraError(MESSAGE_UNEXPECTED);
    }

    /**
     * @description Builds an AuraHandledException whose message is readable by Apex callers and logs as well as the LWC.
     * @param message The user-facing message
     * @return The exception to throw
     **/
    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
