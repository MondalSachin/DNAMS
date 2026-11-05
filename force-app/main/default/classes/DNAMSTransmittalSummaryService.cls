/**
 * @description     Transmittal drafting: writes the package's Ownership and Executive summaries with two prompt
 *                  templates, called serially (the Executive prompt also gets the ownership lines). The contexts
 *                  are built from the run's consolidated extraction JSON (whitelisted fields only, so no SSN, DOB or
 *                  EIN), the package, its PIR fields and the Rule Validation rows. Each call is retried up to
 *                  TransmittalMaxAttempts__c on a rate limit or an unreadable answer. TransmittalSummaryMaxWords__c is
 *                  the length the prompts ask for; a longer answer is kept in full (never trimmed) and noted in the log.
 *                  All model calls happen before any DML. Success: package summaries (HTML, one line per
 *                  model line), two Completed stage rows, run TransmittalProcessingStatus__c Completed. Failure: run
 *                  Failed, an Error stage row and an error log; the package is left unchanged. Never throws.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Abhishek Dutta
 * @last modification details Answers are never trimmed; an over-long answer is kept in full and logged
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Abhishek Dutta  Initial version
 * 1.1   2026-11-05   Abhishek Dutta  Answers are never trimmed; an over-long answer is kept in full and logged
 **/
// Exception to guideline: without sharing because the pipeline and the RMR button both draft for packages the user may not own
// Naming fixed by the build contract; context building is one cohesive unit (as in DNAMSRuleEvaluator); debug only when even the failure record fails
@SuppressWarnings('PMD.ClassNamingConventions,PMD.CyclomaticComplexity,PMD.CognitiveComplexity,PMD.AvoidDebugStatements')
public without sharing class DNAMSTransmittalSummaryService {
    private static final String CLASS_NAME = DNAMSTransmittalSummaryService.class.getName();
    private static final Integer DEFAULT_MAX_ATTEMPTS = 3;
    private static final Integer DEFAULT_MAX_WORDS = 50;
    private static final Integer LONG_TEXT_LENGTH = 32768;
    private static final Integer RAW_LENGTH = 131072;
    private static final String SUCCESS_MESSAGE = 'The transmittal summaries were drafted.';
    private static final String FAILURE_MESSAGE = 'The transmittal summaries could not be drafted. Please try again in a few minutes.';
    private static final List<String> RETRYABLE_MARKERS = new List<String>{ '429', 'rate limit', 'too many requests', 'limit exceeded' };
    private static final Set<String> ISSUE_VERDICTS = new Set<String>{ DNAMSPipelineConstants.VERDICT_FAIL, DNAMSPipelineConstants.VERDICT_CANNOT_DECIDE };
    // IDP action names (DNAMSIDPAction__mdt DeveloperName) the summaries read from
    private static final String DEALER_APPLICATION = 'DealerApplication';
    private static final String ORG_CHART = 'OrgChart';
    private static final String ADDRESS_VERIFICATION = 'AddressVerificationForm';
    private static final String PHOTOGRAPHS = 'PhotographsOfFacility';

    @TestVisible
    private static DNAMSTransmittalAI ai = new DNAMSEinsteinTransmittalAI();

    /**
     * @description What to draft and on whose behalf.
     **/
    public class DraftRequest {
        public Id runId;
        public String draftSource;
        public Integer failingRuleCount;
        public Id requestedBy;
    }

    /**
     * @description Outcome of a draft; message is safe to show to the user.
     **/
    public class DraftResult {
        public Boolean success = false;
        public String message;
        public String ownershipHtml;
        public String executiveHtml;
    }

    /**
     * @description Drafts both summaries for the run's package. Never throws.
     * @param request The draft request
     * @return        The result
     **/
    public static DraftResult draft(DraftRequest request) {
        return new DraftJob(request).execute();
    }

    /**
     * @description Rule Validation rows of the run with Verdict FAIL or CANNOT_DECIDE.
     * @param runId The run
     * @return      The count
     **/
    public static Integer failingRuleCount(Id runId) {
        return [
            SELECT COUNT()
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION AND Verdict__c IN :ISSUE_VERDICTS
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description One summary's model answer across its attempts.
     **/
    private class Generation {
        String summaryType;
        String raw;
        List<String> lines;
        Integer attempts = 0;
        Integer wordCount = 0;
        String error;

        /**
         * @description Starts an empty generation.
         * @param summaryType SUMMARY_OWNERSHIP or SUMMARY_EXECUTIVE
         **/
        public Generation(String summaryType) {
            this.summaryType = summaryType;
        }

        String html() {
            List<String> escaped = new List<String>();
            for (String line : lines) {
                escaped.add(line.escapeHtml4());
            }
            return String.join(escaped, '<br>');
        }
    }

    /**
     * @description State of one draft call: the loaded records, then the model calls, then the DML.
     **/
    private without sharing class DraftJob {
        DraftRequest request;
        AI_Package_Review_Run__c run;
        DNAMS_Package__c pkg;
        List<AIReviewStageResult__c> ruleRows;
        Map<String, Map<String, Object>> documentByAction;
        String requesterName;
        Integer maxAttempts;
        Integer maxWords;

        /**
         * @description Creates the job.
         * @param request The draft request
         **/
        public DraftJob(DraftRequest request) {
            this.request = request;
        }

        DraftResult execute() {
            Generation current;
            try {
                DNAMS_Pipeline_Setting__mdt settings = load();
                current = generate(DNAMSPipelineConstants.SUMMARY_OWNERSHIP, settings.OwnershipSummaryPromptTemplate__c, ownershipContext());
                if (current.error != null) {
                    return fail(current, null);
                }
                Generation ownership = current;
                current = generate(DNAMSPipelineConstants.SUMMARY_EXECUTIVE, settings.ExecutiveSummaryPromptTemplate__c, executiveContext(ownership.lines));
                if (current.error != null) {
                    return fail(current, null);
                }
                return save(ownership, current);
            } catch (Exception e) {
                return fail(current, e);
            }
        }

        DNAMS_Pipeline_Setting__mdt load() {
            run = [
                SELECT Id, Package__c, ConsolidatedExtractionJSON__c, RuleValidationPassRate__c
                FROM AI_Package_Review_Run__c
                WHERE Id = :request.runId
                WITH SYSTEM_MODE
            ];
            pkg = [
                SELECT Id, Name, Type__c, Health__c, AI_Narrative__c, PIR_Linked__c, PIR_Cleared__c, PIR_Bypass_Reason__c, Buying_Dealer__r.Name
                FROM DNAMS_Package__c
                WHERE Id = :run.Package__c
                WITH SYSTEM_MODE
            ];
            ruleRows = [
                SELECT RuleName__c, Verdict__c, SourceValue__c, ReferenceValue__c
                FROM AIReviewStageResult__c
                WHERE ReviewRun__c = :run.Id AND Stage__c = :DNAMSPipelineConstants.STAGE_RULE_VALIDATION
                WITH SYSTEM_MODE
                ORDER BY Name ASC
            ];
            List<User> requesters = [SELECT Name FROM User WHERE Id = :requestedBy() WITH SYSTEM_MODE];
            requesterName = requesters.isEmpty() ? null : requesters[0].Name;
            documentByAction = firstDocumentByAction(run.ConsolidatedExtractionJSON__c);
            DNAMS_Pipeline_Setting__mdt settings = DNAMS_PackageReviewPipelineService.settings();
            maxAttempts = Math.max(1, (settings.TransmittalMaxAttempts__c ?? DEFAULT_MAX_ATTEMPTS).intValue());
            maxWords = Math.max(1, (settings.TransmittalSummaryMaxWords__c ?? DEFAULT_MAX_WORDS).intValue());
            return settings;
        }

        Id requestedBy() {
            return request.requestedBy ?? UserInfo.getUserId();
        }

        // ------------------------------------------------------------------ contexts (Prompt I/O contract)

        Map<String, Object> ownershipContext() {
            return new Map<String, Object>{
                'dealer' => new Map<String, Object>{ 'legalName' => legalName(), 'packageType' => pkg.Type__c },
                'directOwners' => pick(DEALER_APPLICATION, 'OwnershipInfoDirectOwners', new Map<String, String>{
                    'name' => 'NameOfOwner', 'ownershipPercent' => 'OwnershipPercentage', 'votingPercent' => 'VotingPercentage'
                }),
                'indirectOwners' => pick(DEALER_APPLICATION, 'OwnershipInfoIndirectOwners', new Map<String, String>{
                    'name' => 'Name', 'heldThrough' => 'HeldThrough', 'effectivePercent' => 'EffectivePercentageOfDealer'
                }),
                'ownershipStructure' => pick(ORG_CHART, 'OwnershipStructure', new Map<String, String>{
                    'ownerName' => 'OwnerName', 'ownerType' => 'OwnerType', 'ownedEntityName' => 'OwnedEntityName', 'ownershipPercent' => 'OwnershipPercent'
                }),
                'pir' => pir(),
                'maxWords' => maxWords
            };
        }

        Map<String, Object> executiveContext(List<String> ownershipLines) {
            return new Map<String, Object>{
                'package' => new Map<String, Object>{ 'name' => pkg.Name, 'type' => pkg.Type__c, 'health' => pkg.Health__c, 'aiNarrative' => pkg.AI_Narrative__c },
                'dealer' => new Map<String, Object>{
                    'legalName' => legalName(),
                    'tradeName' => text(DEALER_APPLICATION, 'TradeName'),
                    'city' => text(DEALER_APPLICATION, 'DealershipCity'),
                    'state' => text(DEALER_APPLICATION, 'DealershipState'),
                    'regionOrDistrict' => text(DEALER_APPLICATION, 'RegionOrDistrict')
                },
                'ruleValidation' => ruleValidation(),
                'facts' => new Map<String, Object>{
                    'stateDealerLicense' => text(DEALER_APPLICATION, 'StateDealerLicenseNumber'),
                    'premisesHeldBy' => text(ADDRESS_VERIFICATION, 'PremisesHeldBy'),
                    'landlord' => text(ADDRESS_VERIFICATION, 'Landlord'),
                    'bankruptcyDisclosed' => text(DEALER_APPLICATION, 'HasApplicantBeenBankrupt'),
                    'convictionDisclosed' => text(DEALER_APPLICATION, 'HasApplicantBeenConvicted'),
                    'keyManagement' => pick(DEALER_APPLICATION, 'DealerOperatorAndKeyManagement', new Map<String, String>{ 'name' => 'Name', 'title' => 'Title' }),
                    'facilityAreasPhotographed' => items(PHOTOGRAPHS, 'AreasPhotographed')
                },
                'ownershipSummary' => String.join(ownershipLines, '\n'),
                'pir' => pir(),
                'draft' => new Map<String, Object>{ 'source' => request.draftSource, 'failingRuleCount' => failingCount() },
                'maxWords' => maxWords
            };
        }

        String legalName() {
            return text(DEALER_APPLICATION, 'LegalNameOrDealerEntity') ?? pkg.Buying_Dealer__r?.Name;
        }

        Map<String, Object> pir() {
            // Same applicability test as the PIR rule row (DNAMSRuleValidationStarterQueueable.pirRow)
            Boolean applicable = pkg.Type__c != null && DNAMSRuleUtil.pirRequiredTypes().contains(pkg.Type__c.toLowerCase());
            return new Map<String, Object>{
                'applicable' => applicable,
                'linked' => pkg.PIR_Linked__c,
                'cleared' => pkg.PIR_Cleared__c,
                'bypassReason' => pkg.PIR_Bypass_Reason__c
            };
        }

        Map<String, Object> ruleValidation() {
            Integer applicable = 0;
            Integer passed = 0;
            List<Map<String, Object>> failedRules = new List<Map<String, Object>>();
            for (AIReviewStageResult__c row : ruleRows) {
                applicable += row.Verdict__c == DNAMSPipelineConstants.VERDICT_NOT_APPLICABLE ? 0 : 1;
                passed += row.Verdict__c == DNAMSPipelineConstants.VERDICT_PASS ? 1 : 0;
                if (ISSUE_VERDICTS.contains(row.Verdict__c)) {
                    failedRules.add(new Map<String, Object>{ 'ruleName' => row.RuleName__c, 'sourceValue' => row.SourceValue__c, 'referenceValue' => row.ReferenceValue__c });
                }
            }
            return new Map<String, Object>{ 'passRate' => run.RuleValidationPassRate__c, 'applicable' => applicable, 'passed' => passed, 'failedRules' => failedRules };
        }

        Integer failingCount() {
            if (request.failingRuleCount != null) {
                return request.failingRuleCount;
            }
            Integer count = 0;
            for (AIReviewStageResult__c row : ruleRows ?? new List<AIReviewStageResult__c>()) {
                count += ISSUE_VERDICTS.contains(row.Verdict__c) ? 1 : 0;
            }
            return count;
        }

        String text(String action, String field) {
            Object value = documentByAction.get(action.toLowerCase())?.get(field);
            return value == null || String.isBlank(String.valueOf(value)) ? null : String.valueOf(value).trim();
        }

        List<Object> items(String action, String field) {
            Object value = documentByAction.get(action.toLowerCase())?.get(field);
            if (value instanceof String && ((String) value).trim().startsWith('[')) {
                try {
                    value = JSON.deserializeUntyped((String) value); // e.g. OrgChart.OwnershipStructure is a JSON string
                } catch (JSONException notJson) {
                    return new List<Object>(); // unreadable extracted value: summarise without it
                }
            }
            return value instanceof List<Object> ? (List<Object>) value : new List<Object>();
        }

        List<Map<String, Object>> pick(String action, String field, Map<String, String> sourceKeyByName) {
            List<Map<String, Object>> picked = new List<Map<String, Object>>();
            for (Object item : items(action, field)) {
                if (item instanceof Map<String, Object>) {
                    Map<String, Object> source = (Map<String, Object>) item;
                    Map<String, Object> target = new Map<String, Object>();
                    for (String name : sourceKeyByName.keySet()) {
                        target.put(name, source.get(sourceKeyByName.get(name)));
                    }
                    picked.add(target);
                }
            }
            return picked;
        }

        // ------------------------------------------------------------------ model calls

        Generation generate(String summaryType, String promptTemplate, Map<String, Object> context) {
            Generation generation = new Generation(summaryType);
            String contextJson = JSON.serialize(context);
            Boolean done = false;
            while (!done && generation.attempts < maxAttempts) {
                generation.attempts++;
                done = attempt(generation, promptTemplate, contextJson);
            }
            return generation;
        }

        // True when no further attempt should be made (usable answer, or a non-retryable error).
        Boolean attempt(Generation generation, String promptTemplate, String contextJson) {
            generation.lines = null;
            try {
                generation.raw = ai.generate(promptTemplate, contextJson);
            } catch (Exception e) {
                generation.error = e.getTypeName() + ': ' + e.getMessage();
                return !isRetryable(e.getMessage());
            }
            generation.lines = parseLines(generation.raw);
            if (generation.lines == null) {
                generation.error = 'The model answer is not JSON {"lines": [...]} with at least one line.';
                return false;
            }
            generation.error = null;
            generation.wordCount = words(generation.lines);
            return true;
        }

        // ------------------------------------------------------------------ DML (after every model call)

        DraftResult save(Generation ownership, Generation executive) {
            lockRun();
            Savepoint savepoint = Database.setSavepoint();
            try {
                Database.update(new DNAMS_Package__c(
                    Id = pkg.Id,
                    Ownership_Summary__c = ownership.html(),
                    Executive_Summary__c = executive.html(),
                    Transmittal_Drafted_At__c = System.now(),
                    Transmittal_Draft_Source__c = request.draftSource
                ), true, AccessLevel.SYSTEM_MODE);
                Database.insert(new List<AIReviewStageResult__c>{ row(ownership, null), row(executive, null) }, true, AccessLevel.SYSTEM_MODE);
                updateRunStatus(DNAMSPipelineConstants.RUN_STAGE_COMPLETED);
            } catch (Exception e) {
                Database.rollback(savepoint);
                throw e;
            }
            DraftResult result = new DraftResult();
            result.success = true;
            result.message = SUCCESS_MESSAGE;
            result.ownershipHtml = ownership.html();
            result.executiveHtml = executive.html();
            return result;
        }

        DraftResult fail(Generation failed, Exception error) {
            String message = error == null ? failed.error : error.getTypeName() + ': ' + error.getMessage() + '\n' + error.getStackTraceString();
            try {
                lockRun();
                updateRunStatus(DNAMSPipelineConstants.RUN_STAGE_FAILED);
                AIReviewStageResult__c errorRow = row(failed ?? new Generation(null), message);
                Database.insert(errorRow, true, AccessLevel.SYSTEM_MODE);
                DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
                detail.runId = request.runId;
                detail.stageResultId = errorRow.Id;
                detail.stage = DNAMSPipelineConstants.STAGE_TRANSMITTAL;
                detail.severity = DNAMSPipelineConstants.SEVERITY_ERROR;
                detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
                detail.sourceClass = CLASS_NAME;
                detail.message = (failed?.summaryType ?? 'Transmittal') + ' drafting failed: ' + message;
                detail.rawPayload = failed?.raw;
                DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
            } catch (Exception ignored) {
                System.debug(LoggingLevel.ERROR, 'Transmittal failure could not be recorded: ' + ignored.getMessage() + ' (original: ' + message + ')');
            }
            DraftResult result = new DraftResult();
            result.message = FAILURE_MESSAGE;
            return result;
        }

        void lockRun() {
            // Serialises concurrent drafts of the same run (auto job vs RMR button)
            List<AI_Package_Review_Run__c> locked = [SELECT Id FROM AI_Package_Review_Run__c WHERE Id = :request.runId WITH SYSTEM_MODE FOR UPDATE];
            if (locked.isEmpty()) {
                throw new DNAMSPipelineException('The review run no longer exists.');
            }
        }

        void updateRunStatus(String status) {
            Database.update(new AI_Package_Review_Run__c(Id = request.runId, TransmittalProcessingStatus__c = status), true, AccessLevel.SYSTEM_MODE);
        }

        AIReviewStageResult__c row(Generation generation, String errorDetails) {
            Boolean ok = errorDetails == null;
            String reasoning = note() +
                (generation.wordCount > maxWords ? ' The answer has ' + generation.wordCount + ' words (asked for ' + maxWords + '); kept in full.' : '');
            return new AIReviewStageResult__c(
                ReviewRun__c = request.runId,
                Stage__c = DNAMSPipelineConstants.STAGE_TRANSMITTAL,
                SummaryType__c = generation.summaryType,
                Outcome__c = request.draftSource,
                GeneratedText__c = ok ? generation.html() : null,
                RawStageResponseJSON__c = generation.raw?.left(RAW_LENGTH),
                RequestedBy__c = requestedBy(),
                ProcessingStatus__c = ok ? DNAMSPipelineConstants.ROW_COMPLETED : DNAMSPipelineConstants.ROW_ERROR,
                ProcessingErrorDetails__c = errorDetails?.left(LONG_TEXT_LENGTH),
                ProcessingCompletedAt__c = System.now(),
                Reasoning__c = (reasoning + ' Attempts: ' + generation.attempts + '.').left(LONG_TEXT_LENGTH)
            );
        }

        String note() {
            String source = request.draftSource;
            String requester = requesterName ?? UserInfo.getName(); // null only when loading failed
            if (source == DNAMSPipelineConstants.DRAFT_SOURCE_RMR_DRAFT) {
                return 'Drafted by RMR ' + requester + '.';
            }
            if (source == DNAMSPipelineConstants.DRAFT_SOURCE_RMR_REDRAFT) {
                return 'Regenerated by RMR ' + requester + '; previous drafts are kept in earlier rows.';
            }
            if (source == DNAMSPipelineConstants.DRAFT_SOURCE_RMR_OVERRIDE) {
                return 'Drafted by RMR ' + requester + ', who confirmed drafting despite ' + failingCount() + ' failing rule(s).';
            }
            return 'Drafted automatically after rule validation passed (GREEN).';
        }
    }

    // ------------------------------------------------------------------ pure helpers

    /**
     * @description First document's data per IDP action (keys lower-cased), read like DNAMSRuleEvaluator.
     * @param consolidatedJson AI_Package_Review_Run__c.ConsolidatedExtractionJSON__c ({action: [{data: {...}}]})
     * @return                 Data by lower-case action name; empty when nothing was extracted
     **/
    private static Map<String, Map<String, Object>> firstDocumentByAction(String consolidatedJson) {
        Map<String, Map<String, Object>> byAction = new Map<String, Map<String, Object>>();
        if (String.isBlank(consolidatedJson)) {
            return byAction;
        }
        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(consolidatedJson);
        for (String action : raw.keySet()) {
            // shortcut: one document per action is summarised, upgrade if a package can carry two of the same type
            for (Object entry : (List<Object>) raw.get(action)) {
                Object data = ((Map<String, Object>) entry).get('data');
                if (data instanceof Map<String, Object>) {
                    byAction.put(action.toLowerCase(), (Map<String, Object>) data);
                    break;
                }
            }
        }
        return byAction;
    }

    /**
     * @description Whether a model error is a rate limit worth retrying.
     * @param message The exception message
     * @return        True for 429 / rate limit / too many requests / limit exceeded
     **/
    @TestVisible
    private static Boolean isRetryable(String message) {
        String lower = (message ?? '').toLowerCase();
        for (String marker : RETRYABLE_MARKERS) {
            if (lower.contains(marker)) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description Reads {"lines": [...]} from the model text (code fences or text around it are ignored).
     * @param raw The model text
     * @return    The non-blank lines, or null when there are none or the text is not that JSON
     **/
    @TestVisible
    private static List<String> parseLines(String raw) {
        Integer start = raw?.indexOf('{') ?? -1;
        Integer finish = raw?.lastIndexOf('}') ?? -1;
        if (start < 0 || finish <= start) {
            return null;
        }
        List<String> lines = new List<String>();
        try {
            for (Object line : (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(raw.substring(start, finish + 1))).get('lines')) {
                if (line != null && String.isNotBlank(String.valueOf(line))) {
                    lines.add(String.valueOf(line).trim());
                }
            }
        } catch (Exception notLines) {
            return null; // not JSON, not an object, or "lines" missing / not a list
        }
        return lines.isEmpty() ? null : lines;
    }

    /**
     * @description Word count across lines.
     * @param lines The lines
     * @return      Number of whitespace-separated words
     **/
    @TestVisible
    private static Integer words(List<String> lines) {
        return String.join(lines, ' ').normalizeSpace().split(' ').size();
    }
}
