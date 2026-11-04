/**
 * @description     Reads the rule validation rules (DNAMSRule__mdt, diagram rule validation step 3) and the shared helpers
 *                  of the rule validation stage: which rules apply to a package, key parsing and safe job chaining.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Sachin Mondal   Initial version
 **/
public inherited sharing class DNAMSRuleUtil {
    // Tests inject rules here so they never depend on the deployed CMDT records.
    @TestVisible
    private static List<DNAMSRule__mdt> rulesOverride;

    /**
     * @description Active rules in SortOrder__c order. SOQL (not getAll) because getAll truncates long text area fields.
     * @return      Active rules
     **/
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static List<DNAMSRule__mdt> getRules() {
        // PMD.ApexCRUDViolation suppressed: CMDT is pipeline configuration, read in system mode.
        List<DNAMSRule__mdt> rules = rulesOverride ?? [
            SELECT DeveloperName, MasterLabel, Description__c, AIInstructions__c, RuleType__c, RelativeElementType__c,
                ValidationMethod__c, RuleAppliedTo__c, RelativePackageType__c, SourceFieldType__c, SourceFieldKey__c,
                Comparator__c, ReferenceFieldType__c, ReferenceFieldKey__c, IsActive__c, SortOrder__c
            FROM DNAMSRule__mdt
            WHERE IsActive__c = TRUE
            ORDER BY SortOrder__c ASC NULLS LAST, DeveloperName ASC
        ];
        List<DNAMSRule__mdt> active = new List<DNAMSRule__mdt>();
        for (DNAMSRule__mdt rule : rules) {
            if (rule.IsActive__c) {
                active.add(rule);
            }
        }
        return active;
    }

    /**
     * @description Active rules keyed by rule id (DeveloperName).
     * @return      Rules by id
     **/
    public static Map<String, DNAMSRule__mdt> getRulesById() {
        Map<String, DNAMSRule__mdt> rulesById = new Map<String, DNAMSRule__mdt>();
        for (DNAMSRule__mdt rule : getRules()) {
            rulesById.put(rule.DeveloperName, rule);
        }
        return rulesById;
    }

    /**
     * @description Whether a rule runs for a package of this type: a blank RelativePackageType__c means every type;
     *              package-level rules always name their type.
     * @param rule        The rule
     * @param packageType DNAMS_Package__c.Type__c
     * @return            True when the rule applies
     **/
    public static Boolean appliesTo(DNAMSRule__mdt rule, String packageType) {
        if (String.isBlank(rule.RelativePackageType__c)) {
            return rule.RuleAppliedTo__c != DNAMSPipelineConstants.APPLIED_TO_PACKAGE;
        }
        return packageType != null && rule.RelativePackageType__c.trim().equalsIgnoreCase(packageType.trim());
    }

    /**
     * @description Reads a field key: a JSON array of keys, or one key.
     * @param raw The SourceFieldKey__c / ReferenceFieldKey__c value
     * @return    The keys (one blank key for a blank value, e.g. a Static '')
     **/
    public static List<String> parseKeys(String raw) {
        String trimmed = raw == null ? '' : raw.trim();
        if (trimmed.startsWith('[')) {
            try {
                List<String> keys = new List<String>();
                for (Object key : (List<Object>) JSON.deserializeUntyped(trimmed)) {
                    keys.add(key == null ? '' : String.valueOf(key));
                }
                return keys;
            } catch (JSONException notJson) {
                return new List<String>{ trimmed }; // a literal that only starts with '['
            }
        }
        return new List<String>{ trimmed == '\'\'' || trimmed == '""' ? '' : trimmed };
    }

    /**
     * @description Package types that need a PIR (DNAMS_Pipeline_Setting__mdt.PIRRequiredPackageTypes__c).
     * @return      Lower-case package types
     **/
    public static Set<String> pirRequiredTypes() {
        Set<String> types = new Set<String>();
        String configured = DNAMS_PackageReviewPipelineService.settings().PIRRequiredPackageTypes__c;
        for (String type : (configured ?? '').split(';')) {
            if (String.isNotBlank(type)) {
                types.add(type.trim().toLowerCase());
            }
        }
        return types;
    }

    /**
     * @description Enqueues a job when the platform allows it.
     * @param job The job
     * @return    Null when queued, else why it was not
     **/
    public static String tryEnqueue(Queueable job) {
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return 'queueable job limit reached';
        }
        try {
            System.enqueueJob(job);
            return null;
        } catch (AsyncException asyncError) {
            return asyncError.getMessage(); // e.g. the chain depth limit in tests
        }
    }

    /**
     * @description Records an unexpected rule validation failure: rolls back, fails the run's rule validation stage
     *              and writes a Processing Error log. Never throws.
     * @param runId       The run
     * @param error       The exception
     * @param sourceClass The class that caught it
     **/
    public static void failStage(Id runId, Exception error, String sourceClass) {
        try {
            DNAMS_PackageReviewPipelineService.failRun(runId, AI_Package_Review_Run__c.RuleValidationProcessingStatus__c, error);
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = runId;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.stage = DNAMSPipelineConstants.STAGE_RULE_VALIDATION;
            detail.sourceClass = sourceClass;
            detail.message = error.getTypeName() + ': ' + error.getMessage() + '\n' + error.getStackTraceString();
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
        } catch (Exception ignored) {
            System.debug(LoggingLevel.ERROR, 'Rule validation failure could not be recorded: ' + ignored.getMessage());
        }
    }
}
