/**
 * @description     "Re-run changes only" foundation. A Changes Only run compares against its baseline (the package's
 *                  last non-Discarded run) and, per unit, either reuses the baseline AIReviewStageResult__c row (copied
 *                  into the new run with ReusedFromResult__c) or runs the unit again. Detection is data-only: it uses
 *                  the fields already on the stage rows (no fingerprints); prompt, rule and config changes are out of
 *                  scope (use Re-run all). This class only compares and copies; each stage decides what to reuse.
 *                  Units and keys:
 *                    Classification / Extraction: one file on an element -> fileKey "elementId|contentDocumentId|contentVersionId"
 *                    Rule Validation: one rule -> ruleKey = RuleId__c (one row per rule per run; PIR row RuleId "PIR")
 *                  "Finished OK" (a baseline row that may be reused when its inputs are unchanged):
 *                    Classification: ProcessingStatus__c Completed (Outcome__c Match / Wrong / Unsure / Unclassified,
 *                                    so failing answers are reused too); Error rows always run again.
 *                    Extraction:     ProcessingStatus__c Completed, SchemaValidationStatus__c Passed and a stored
 *                                    RawStageResponseJSON__c; Pending / In Progress / Error / Failed (Timeout) and
 *                                    schema failures always run again.
 *                    Rule (AIMatch): ProcessingStatus__c Completed, a Verdict__c and a stored RawStageResponseJSON__c
 *                                    (the model answered); a CANNOT_DECIDE written because the AI call failed has no
 *                                    raw answer and runs again. ExactMatch and PIR rows are never reused.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details summaryNeeded also compares Issue_Summary__c (pre-flight stops write no stage rows)
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 * 1.1   2026-11-10   Abhishek Dutta  summaryNeeded also compares Issue_Summary__c
 **/
// Exception to guideline: without sharing because the pipeline (integration user) and the RMR re-run modal must compare every run and stage row of the package regardless of ownership
@SuppressWarnings('PMD.ExcessivePublicCount, PMD.CyclomaticComplexity')
public without sharing class DNAMSRunChangeDetector {
    public static final String KEY_SEPARATOR = '|';

    // FileChange.kind
    public static final String CHANGE_UNCHANGED = 'Unchanged';
    public static final String CHANGE_NEW_VERSION = 'New version';
    public static final String CHANGE_ADDED = 'Added';
    public static final String CHANGE_REMOVED = 'Removed';
    public static final String CHANGE_UNFINISHED = 'Unfinished';

    // Stage labels used in ChangeSummary__c lines (Stage__c values plus the steps that have no stage rows)
    public static final String SUMMARY_PREFLIGHT = 'Pre-flight';
    public static final String SUMMARY_CLASSIFICATION = 'Classification';
    public static final String SUMMARY_EXTRACTION = 'Extraction';
    public static final String SUMMARY_RULE_VALIDATION = 'Rule Validation';
    public static final String SUMMARY_PIR = 'PIR';
    public static final String SUMMARY_AI_SUMMARY = 'AI Summary';
    public static final String SUMMARY_TRANSMITTAL = 'Transmittal Drafting';

    private static final Integer SUMMARY_LENGTH = 32768;
    private static final Integer VALUE_LENGTH = 32768;
    private static final String RUN_COMPLETED = 'Completed';

    /** Result fields copied by cloneForReuse (everything that describes the result; Document__c is a formula). */
    public static final List<String> CLONE_FIELDS = new List<String>{
        'Stage__c', 'PackageElement__c', 'ElementType__c', 'DocumentTitle__c', 'DocumentType__c', 'ContentDocumentId__c',
        'ContentVersionId__c', 'Confidence__c', 'Outcome__c', 'Reasoning__c', 'RawStageResponseJSON__c',
        'ProcessingStatus__c', 'ProcessingErrorDetails__c', 'ProcessingCompletedAt__c', 'SubmittedAt__c',
        'IDPActionName__c', 'IDPActionId__c', 'IDPActionVersion__c', 'MuleSoftExecutionStatus__c',
        'SchemaValidationStatus__c', 'RuleId__c', 'RuleName__c', 'RuleType__c', 'ComparisonMethod__c',
        'SourceValue__c', 'ReferenceValue__c', 'Verdict__c', 'SummaryType__c', 'GeneratedText__c', 'RequestedBy__c'
    };

    /**
     * Fields cloneForReuse leaves blank: CallbackToken__c and MuleSoftExecutionId__c are unique and route IDP callbacks
     * to a row; the callback payload/time belong to the original row (reach it through ReusedFromResult__c).
     */
    public static final List<String> CLEARED_FIELDS = new List<String>{
        'CallbackToken__c', 'MuleSoftExecutionId__c', 'CallbackPayload__c', 'CallbackReceivedAt__c'
    };

    // ------------------------------------------------------------------ Baseline and mode

    /**
     * @description The package's last non-Discarded run (any outcome), newest by CreatedDate then Name.
     * @param packageId    DNAMS_Package__c id
     * @param excludeRunId Run to ignore (usually the new run); may be null
     * @return             The baseline run (Id, Name, Status__c, Overall_Result__c, stage statuses), or null
     **/
    public static AI_Package_Review_Run__c baselineFor(Id packageId, Id excludeRunId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, Name, Package__c, Status__c, Overall_Result__c, Classification_Processing_Status__c,
                ExtractionProcessingStatus__c, RuleValidationProcessingStatus__c, TransmittalProcessingStatus__c,
                ConsolidatedExtractionJSON__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId
                AND Status__c != :DNAMS_PackageReviewPipelineService.RUN_DISCARDED
                AND Id != :excludeRunId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Name DESC
            LIMIT 1
        ];
        return runs.isEmpty() ? null : runs[0];
    }

    /**
     * @description Bulk baseline lookup for runs that do not exist yet (used when the review request creates the run).
     * @param packageIds DNAMS_Package__c ids
     * @return           Last non-Discarded run per package (Id, Name, Status__c); packages without one are absent
     **/
    public static Map<Id, AI_Package_Review_Run__c> baselinesFor(Set<Id> packageIds) {
        Map<Id, AI_Package_Review_Run__c> baselineByPackage = new Map<Id, AI_Package_Review_Run__c>();
        if (packageIds == null || packageIds.isEmpty()) {
            return baselineByPackage;
        }
        for (AI_Package_Review_Run__c run : [
            SELECT Id, Name, Package__c, Status__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c IN :packageIds AND Status__c != :DNAMS_PackageReviewPipelineService.RUN_DISCARDED
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Name DESC
        ]) {
            if (!baselineByPackage.containsKey(run.Package__c)) {
                baselineByPackage.put(run.Package__c, run);
            }
        }
        return baselineByPackage;
    }

    /**
     * @description Normalises an event/UI mode value: "Changes Only" (any case) stays Changes Only; anything else is All.
     * @param mode Raw mode (may be blank)
     * @return     DNAMSPipelineConstants.RERUN_MODE_ALL or RERUN_MODE_CHANGES_ONLY
     **/
    public static String normaliseMode(String mode) {
        return DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY.equalsIgnoreCase(mode?.trim())
            ? DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY
            : DNAMSPipelineConstants.RERUN_MODE_ALL;
    }

    /**
     * @description The baseline a stage must compare with: BaselineRun__c when the run is Changes Only, else null.
     *              Stages call this once at their start; null means "run everything" (today's behaviour).
     * @param runId AI_Package_Review_Run__c id
     * @return      Baseline run id, or null
     **/
    public static Id baselineRunIdFor(Id runId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT RerunMode__c, BaselineRun__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE
        ];
        if (runs.isEmpty() || runs[0].RerunMode__c != DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY) {
            return null;
        }
        return runs[0].BaselineRun__c;
    }

    // ------------------------------------------------------------------ Keys and "finished OK"

    /**
     * @description Unit key of a file on an element.
     * @param elementId         DNAMS_Package_Element__c id
     * @param contentDocumentId ContentDocument id
     * @param contentVersionId  ContentVersion id (the latest published version that was / will be processed)
     * @return                  "elementId|contentDocumentId|contentVersionId" (18-character ids)
     **/
    public static String fileKey(Id elementId, Id contentDocumentId, Id contentVersionId) {
        return String.valueOf(elementId) + KEY_SEPARATOR + String.valueOf(contentDocumentId) + KEY_SEPARATOR + String.valueOf(contentVersionId);
    }

    /**
     * @description Unit key of a Classification or Extraction row.
     * @param row Stage row with PackageElement__c, ContentDocumentId__c, ContentVersionId__c
     * @return    fileKey of the row
     **/
    public static String fileKey(AIReviewStageResult__c row) {
        return fileKey(row.PackageElement__c, toId(row.ContentDocumentId__c), toId(row.ContentVersionId__c));
    }

    /**
     * @description Unit key of a Rule Validation row.
     * @param row Stage row with RuleId__c
     * @return    RuleId__c
     **/
    public static String ruleKey(AIReviewStageResult__c row) {
        return row.RuleId__c;
    }

    /**
     * @description Whether a Classification row finished (any answer, including failing ones).
     * @param row Classification row
     * @return    True when ProcessingStatus__c is Completed and Outcome__c is not Error
     **/
    public static Boolean isFinishedClassification(AIReviewStageResult__c row) {
        return row != null &&
            row.ProcessingStatus__c == DNAMSPipelineConstants.ROW_COMPLETED &&
            row.Outcome__c != DNAMS_DocumentClassificationBatch.OUTCOME_ERROR;
    }

    /**
     * @description Whether an Extraction row succeeded and holds a payload that passed the structure check.
     * @param row Extraction row
     * @return    True when Completed, SchemaValidationStatus__c Passed and RawStageResponseJSON__c is stored
     **/
    public static Boolean isFinishedExtraction(AIReviewStageResult__c row) {
        return row != null &&
            row.ProcessingStatus__c == DNAMSPipelineConstants.ROW_COMPLETED &&
            row.SchemaValidationStatus__c == DNAMSPipelineConstants.SCHEMA_PASSED &&
            String.isNotBlank(row.RawStageResponseJSON__c);
    }

    /**
     * @description Whether an AIMatch rule row holds a model verdict.
     * @param row Rule Validation row
     * @return    True when AIMatch, Completed, with a Verdict__c and the model's raw answer
     **/
    public static Boolean isFinishedAiRule(AIReviewStageResult__c row) {
        return row != null &&
            row.ComparisonMethod__c == DNAMSPipelineConstants.METHOD_AI &&
            row.ProcessingStatus__c == DNAMSPipelineConstants.ROW_COMPLETED &&
            String.isNotBlank(row.Verdict__c) &&
            String.isNotBlank(row.RawStageResponseJSON__c);
    }

    // ------------------------------------------------------------------ Baseline rows

    /**
     * @description Every row of one stage of a run, with all CLONE_FIELDS (plus Id, Name, ReviewRun__c,
     *              ReusedFromResult__c), oldest first.
     * @param runId AI_Package_Review_Run__c id
     * @param stage Stage__c value
     * @return      Rows (empty when runId is null)
     **/
    public static List<AIReviewStageResult__c> stageRows(Id runId, String stage) {
        return stageRows(new Set<Id>{ runId }, stage);
    }

    /**
     * @description Finished Classification rows of the baseline, keyed by fileKey.
     * @param baselineRunId Baseline run id
     * @return              Reusable rows (see isFinishedClassification)
     **/
    public static Map<String, AIReviewStageResult__c> reusableClassificationRows(Id baselineRunId) {
        Map<String, AIReviewStageResult__c> rowsByKey = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baselineRunId, DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION)) {
            if (isFinishedClassification(row)) {
                rowsByKey.put(fileKey(row), row);
            }
        }
        return rowsByKey;
    }

    /**
     * @description Successful Extraction rows of the baseline, keyed by fileKey. Callers still check
     *              extractionStillValid against the current document type and IDP action.
     * @param baselineRunId Baseline run id
     * @return              Reusable rows (see isFinishedExtraction)
     **/
    public static Map<String, AIReviewStageResult__c> reusableExtractionRows(Id baselineRunId) {
        Map<String, AIReviewStageResult__c> rowsByKey = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baselineRunId, DNAMSPipelineConstants.STAGE_EXTRACTION)) {
            if (isFinishedExtraction(row)) {
                rowsByKey.put(fileKey(row), row);
            }
        }
        return rowsByKey;
    }

    /**
     * @description Finished AIMatch rule rows of the baseline, keyed by RuleId__c. ExactMatch and PIR rows are not
     *              returned (they are always evaluated again).
     * @param baselineRunId Baseline run id
     * @return              Reusable rows (see isFinishedAiRule)
     **/
    public static Map<String, AIReviewStageResult__c> reusableRuleRows(Id baselineRunId) {
        Map<String, AIReviewStageResult__c> rowsByKey = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baselineRunId, DNAMSPipelineConstants.STAGE_RULE_VALIDATION)) {
            if (isFinishedAiRule(row)) {
                rowsByKey.put(ruleKey(row), row);
            }
        }
        return rowsByKey;
    }

    /**
     * @description Whether a baseline extraction can be reused for a file that was not re-classified.
     * @param baselineRow    Baseline Extraction row (from reusableExtractionRows)
     * @param currentDocType The file's current document type (ContentVersion.DocumentClassifiedAs__c)
     * @param currentAction  Current IDP action for that type (DNAMSIDPActionUtil.getActionsByDocumentType()), or null
     * @return               True when finished OK and the document type, action name, id and version are unchanged
     **/
    public static Boolean extractionStillValid(AIReviewStageResult__c baselineRow, String currentDocType, DNAMSIDPWrapper.ActionConfig currentAction) {
        return extractionChangeReason(baselineRow, currentDocType, currentAction) == null;
    }

    /**
     * @description Why a baseline extraction cannot be reused, for ChangeSummary__c; null when it can.
     * @param baselineRow    Baseline Extraction row, or null when the baseline has none for the file
     * @param currentDocType The file's current document type
     * @param currentAction  Current IDP action for that type, or null
     * @return               Short reason, e.g. "IDP action version 1.0.0 -> 1.1.0", or null
     **/
    public static String extractionChangeReason(AIReviewStageResult__c baselineRow, String currentDocType, DNAMSIDPWrapper.ActionConfig currentAction) {
        if (baselineRow == null) {
            return 'not extracted before';
        }
        if (!isFinishedExtraction(baselineRow)) {
            return 'did not succeed before';
        }
        if (!sameText(baselineRow.DocumentType__c, currentDocType)) {
            return 'document type ' + baselineRow.DocumentType__c + ' -> ' + currentDocType;
        }
        if (currentAction == null) {
            return 'no IDP action for ' + currentDocType;
        }
        if (baselineRow.IDPActionName__c != currentAction.developerName || baselineRow.IDPActionId__c != currentAction.actionId) {
            return 'IDP action ' + baselineRow.IDPActionName__c + ' -> ' + currentAction.developerName;
        }
        if (baselineRow.IDPActionVersion__c != currentAction.actionVersion) {
            return 'IDP action version ' + baselineRow.IDPActionVersion__c + ' -> ' + currentAction.actionVersion;
        }
        return null;
    }

    /**
     * @description Whether a baseline AIMatch verdict still holds for freshly resolved values. Compare the values exactly
     *              as they would be stored (the rule starter truncates to 32768 characters; this method truncates too).
     * @param baselineRow    Baseline rule row (from reusableRuleRows)
     * @param sourceValue    Resolved SourceValue (DNAMSRuleEvaluator.Outcome.sourceValue)
     * @param referenceValue Resolved ReferenceValue (DNAMSRuleEvaluator.Outcome.referenceValue)
     * @return               True when the row finished and both values are equal (case-sensitive; blank equals null)
     **/
    public static Boolean ruleStillValid(AIReviewStageResult__c baselineRow, String sourceValue, String referenceValue) {
        return isFinishedAiRule(baselineRow) &&
            sameValue(baselineRow.SourceValue__c, sourceValue) &&
            sameValue(baselineRow.ReferenceValue__c, referenceValue);
    }

    // ------------------------------------------------------------------ Reuse

    /**
     * @description Copy of a baseline row for the new run (not inserted). Copies every CLONE_FIELDS value, sets
     *              ReviewRun__c and ReusedFromResult__c (the row that originally produced the result: the baseline
     *              row's own ReusedFromResult__c when it was itself a copy), and leaves CLEARED_FIELDS blank, so a
     *              reused Extraction row is terminal (Completed) and no IDP callback, submit batch or cleanup job
     *              ever picks it up.
     * @param baselineRow Row queried with CLONE_FIELDS (stageRows / reusable*Rows)
     * @param newRunId    The Changes Only run
     * @return            Unsaved AIReviewStageResult__c
     **/
    public static AIReviewStageResult__c cloneForReuse(AIReviewStageResult__c baselineRow, Id newRunId) {
        AIReviewStageResult__c copy = new AIReviewStageResult__c(
            ReviewRun__c = newRunId,
            ReusedFromResult__c = baselineRow.ReusedFromResult__c ?? baselineRow.Id
        );
        Map<String, Object> populated = baselineRow.getPopulatedFieldsAsMap();
        for (String field : CLONE_FIELDS) {
            if (populated.containsKey(field)) {
                copy.put(field, populated.get(field));
            }
        }
        return copy;
    }

    /**
     * @description cloneForReuse for many rows.
     * @param baselineRows Rows queried with CLONE_FIELDS
     * @param newRunId     The Changes Only run
     * @return             Unsaved copies, in the same order
     **/
    public static List<AIReviewStageResult__c> cloneForReuse(List<AIReviewStageResult__c> baselineRows, Id newRunId) {
        List<AIReviewStageResult__c> copies = new List<AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : baselineRows ?? new List<AIReviewStageResult__c>()) {
            copies.add(cloneForReuse(row, newRunId));
        }
        return copies;
    }

    // ------------------------------------------------------------------ Change summary

    /**
     * @description Standard stage line text: "2 reused, 1 re-run (Org Chart: new version; ...)".
     * @param reused  Units reused from the baseline
     * @param rerun   Units run again
     * @param reasons One reason per re-run unit, e.g. "Org Chart / chart.pdf: new version" (may be empty)
     * @return        The text for appendChangeSummary
     **/
    public static String stageLine(Integer reused, Integer rerun, List<String> reasons) {
        String line = (reused ?? 0) + ' reused, ' + (rerun ?? 0) + ' re-run';
        if (reasons != null && !reasons.isEmpty()) {
            line += ' (' + String.join(reasons, '; ') + ')';
        }
        return line;
    }

    /**
     * @description Appends "<stage>: <text>" as a new line to the run's ChangeSummary__c (locks the run row; max
     *              32768 characters). One DML; call once per stage, outside loops.
     * @param runId AI_Package_Review_Run__c id
     * @param stage One of the SUMMARY_* labels
     * @param text  Line text, e.g. stageLine(...)
     **/
    public static void appendChangeSummary(Id runId, String stage, String text) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE FOR UPDATE
        ];
        if (runs.isEmpty()) {
            return;
        }
        String existing = runs[0].ChangeSummary__c;
        String line = (String.isBlank(stage) ? '' : stage + ': ') + (text ?? '');
        Database.update(
            new AI_Package_Review_Run__c(Id = runId, ChangeSummary__c = ((String.isBlank(existing) ? '' : existing + '\n') + line).left(SUMMARY_LENGTH)),
            true,
            AccessLevel.SYSTEM_MODE
        );
    }

    // ------------------------------------------------------------------ AI summary / transmittal gate

    /**
     * @description Whether the AI summary (package narrative) and transmittal must be drafted again. Always true for an
     *              All run or a Changes Only run without a baseline. For Changes Only: true when any Classification,
     *              Extraction or AIMatch row was produced in this run (ReusedFromResult__c blank), when the set of files
     *              or rules differs from the baseline, when any verdict (Classification outcome, ExactMatch, AIMatch,
     *              PIR) differs, or when the run's Issue_Summary__c differs from the baseline's (covers runs that both
     *              stopped at pre-flight, which write no stage rows).
     *              Call after rule validation (or after the stage that ended the run) has written its rows.
     * @param runId The run
     * @return      True when the summaries must be redrafted
     **/
    public static Boolean summaryNeeded(Id runId) {
        Id baselineRunId = baselineRunIdFor(runId);
        if (baselineRunId == null) {
            return true;
        }
        Set<String> stages = new Set<String>{
            DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION,
            DNAMSPipelineConstants.STAGE_EXTRACTION,
            DNAMSPipelineConstants.STAGE_RULE_VALIDATION
        };
        Map<String, String> currentByKey = new Map<String, String>();
        Map<String, String> baselineByKey = new Map<String, String>();
        for (AIReviewStageResult__c row : stageRows(new Set<Id>{ runId, baselineRunId }, stages)) {
            Boolean isCurrent = row.ReviewRun__c == runId;
            if (isCurrent && producedHere(row)) {
                return true;
            }
            String key = row.Stage__c + KEY_SEPARATOR + (row.Stage__c == DNAMSPipelineConstants.STAGE_RULE_VALIDATION ? ruleKey(row) : fileKey(row));
            String verdict = row.Stage__c == DNAMSPipelineConstants.STAGE_RULE_VALIDATION ? row.Verdict__c : row.Outcome__c;
            (isCurrent ? currentByKey : baselineByKey).put(key, verdict ?? '');
        }
        return !currentByKey.equals(baselineByKey) || issueSummaryChanged(runId, baselineRunId);
    }

    /**
     * @description Whether the run's Issue_Summary__c differs from the baseline's. Catches what stage rows cannot show,
     *              e.g. two runs that both stopped at pre-flight (no stage rows) with different file problems.
     * @param runId         The run
     * @param baselineRunId Its baseline
     * @return              True when the issue summaries differ (blank equals null; case-sensitive)
     **/
    private static Boolean issueSummaryChanged(Id runId, Id baselineRunId) {
        Set<Id> runIds = new Set<Id>{ runId, baselineRunId };
        Map<Id, AI_Package_Review_Run__c> runById = new Map<Id, AI_Package_Review_Run__c>([
            SELECT Id, Issue_Summary__c FROM AI_Package_Review_Run__c WHERE Id IN :runIds WITH SYSTEM_MODE
        ]);
        String current = runById.get(runId)?.Issue_Summary__c ?? '';
        return !current.equals(runById.get(baselineRunId)?.Issue_Summary__c ?? '');
    }

    /**
     * @description Whether a row of the current run was produced (not reused) in a way that counts as "re-ran something".
     *              ExactMatch and PIR rows are always evaluated again, so only their verdicts count.
     * @param row Current run row
     * @return    True for a Classification / Extraction / AIMatch row without ReusedFromResult__c
     **/
    private static Boolean producedHere(AIReviewStageResult__c row) {
        if (row.ReusedFromResult__c != null) {
            return false;
        }
        return row.Stage__c != DNAMSPipelineConstants.STAGE_RULE_VALIDATION || row.ComparisonMethod__c == DNAMSPipelineConstants.METHOD_AI;
    }

    // ------------------------------------------------------------------ File changes (classification units)

    /**
     * @description Current files of the package's elements against the baseline's Classification rows. Each current
     *              file is Unchanged (finished baseline row with the same key; baselineRow set), Unfinished (baseline
     *              row with the same key that did not finish), New version (baseline has the document on the element
     *              with another version) or Added (no baseline row for the document on the element). Baseline files no
     *              longer on their element are Removed (they get no row in the new run).
     * @param packageId     DNAMS_Package__c id
     * @param baselineRunId Baseline run id (null: every file is Added)
     * @return              One FileChange per current file plus one per removed file, in element sort order
     **/
    public static List<FileChange> fileChanges(Id packageId, Id baselineRunId) {
        Map<Id, DNAMS_Package_Element__c> elementById = new Map<Id, DNAMS_Package_Element__c>([
            SELECT Id, Name FROM DNAMS_Package_Element__c WHERE Package__c = :packageId WITH SYSTEM_MODE ORDER BY Sort_Order__c ASC NULLS LAST
        ]);
        Map<String, AIReviewStageResult__c> rowByKey = new Map<String, AIReviewStageResult__c>();
        Map<String, AIReviewStageResult__c> rowByDocument = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baselineRunId, DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION)) {
            rowByKey.put(fileKey(row), row);
            rowByDocument.put(row.PackageElement__c + KEY_SEPARATOR + toId(row.ContentDocumentId__c), row);
        }
        List<FileChange> changes = new List<FileChange>();
        Set<String> currentDocuments = new Set<String>();
        if (!elementById.isEmpty()) {
            for (ContentDocumentLink link : [
                SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension,
                    ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :elementById.keySet()
                WITH SYSTEM_MODE
                ORDER BY ContentDocument.CreatedDate
            ]) {
                FileChange change = new FileChange();
                change.elementId = link.LinkedEntityId;
                change.elementName = elementById.get(link.LinkedEntityId).Name;
                change.contentDocumentId = link.ContentDocumentId;
                change.contentVersionId = link.ContentDocument.LatestPublishedVersionId;
                change.title = link.ContentDocument.Title + (String.isBlank(link.ContentDocument.FileExtension) ? '' : '.' + link.ContentDocument.FileExtension);
                String documentKey = change.elementId + KEY_SEPARATOR + change.contentDocumentId;
                currentDocuments.add(documentKey);
                change.baselineRow = rowByKey.get(change.key());
                if (change.baselineRow != null) {
                    change.kind = isFinishedClassification(change.baselineRow) ? CHANGE_UNCHANGED : CHANGE_UNFINISHED;
                } else {
                    change.kind = rowByDocument.containsKey(documentKey) ? CHANGE_NEW_VERSION : CHANGE_ADDED;
                }
                changes.add(change);
            }
        }
        for (String documentKey : rowByDocument.keySet()) {
            if (!currentDocuments.contains(documentKey)) {
                changes.add(removedChange(rowByDocument.get(documentKey), elementById));
            }
        }
        return changes;
    }

    /**
     * @description FileChange for a baseline file that is no longer on its element.
     * @param row         Baseline Classification row
     * @param elementById Current elements of the package
     * @return            The Removed change
     **/
    private static FileChange removedChange(AIReviewStageResult__c row, Map<Id, DNAMS_Package_Element__c> elementById) {
        FileChange change = new FileChange();
        change.kind = CHANGE_REMOVED;
        change.elementId = row.PackageElement__c;
        change.elementName = elementById.get(row.PackageElement__c)?.Name ?? row.ElementType__c;
        change.contentDocumentId = toId(row.ContentDocumentId__c);
        change.contentVersionId = toId(row.ContentVersionId__c);
        change.title = row.DocumentTitle__c;
        change.baselineRow = row;
        return change;
    }

    // ------------------------------------------------------------------ Preview (Re-run modal)

    /**
     * @description What a Changes Only run would do, before it exists: file changes against the baseline's
     *              Classification rows, extraction changes (IDP action/version, newly mapped or unfinished rows) and,
     *              when no file or extraction changed and the baseline finished rule validation, rule value / rule set /
     *              PIR changes (rules resolved with the baseline's consolidated extraction). A baseline that did not
     *              complete always counts as changed (its unfinished stages run again).
     * @param packageId DNAMS_Package__c id
     * @return          The preview; hasChanges false means Changes Only must be blocked
     **/
    public static Preview preview(Id packageId) {
        Preview result = new Preview();
        AI_Package_Review_Run__c baseline = baselineFor(packageId, null);
        if (baseline == null) {
            result.text = 'There is no earlier review run to compare with. Use Re-run all.';
            return result;
        }
        result.hasBaseline = true;
        result.baselineRunId = baseline.Id;
        result.baselineRunName = baseline.Name;
        if (baseline.Status__c != RUN_COMPLETED) {
            result.lines.add(baseline.Name + ' did not finish (' + baseline.Status__c + '); its unfinished stages run again.');
        }
        result.fileChanges = fileChanges(packageId, baseline.Id);
        Boolean filesChanged = false;
        for (FileChange change : result.fileChanges) {
            if (change.kind != CHANGE_UNCHANGED) {
                filesChanged = true;
                result.lines.add(change.describe(baseline.Name));
            }
        }
        List<String> extractionLines = baseline.ExtractionProcessingStatus__c == null
            ? new List<String>()
            : extractionPreview(baseline.Id, result.fileChanges);
        result.lines.addAll(extractionLines);
        if (filesChanged || !extractionLines.isEmpty()) {
            result.lines.add('Rules are re-checked after extraction.');
        } else if (baseline.RuleValidationProcessingStatus__c == DNAMSPipelineConstants.RUN_STAGE_COMPLETED) {
            result.lines.addAll(rulePreview(packageId, baseline));
        }
        result.hasChanges = !result.lines.isEmpty();
        result.text = result.hasChanges
            ? 'Compared with ' + baseline.Name + ':\n- ' + String.join(result.lines, '\n- ')
            : 'Nothing has changed since ' + baseline.Name + '. Use Re-run all to run everything again.';
        return result;
    }

    /**
     * @description Extraction lines for unchanged files: IDP action or version changed, newly mapped, no longer mapped,
     *              or the baseline extraction did not succeed.
     * @param baselineRunId Baseline run id
     * @param changes       File changes from fileChanges
     * @return              Human-readable lines (empty when nothing changed)
     **/
    private static List<String> extractionPreview(Id baselineRunId, List<FileChange> changes) {
        Map<String, AIReviewStageResult__c> rowByKey = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baselineRunId, DNAMSPipelineConstants.STAGE_EXTRACTION)) {
            rowByKey.put(fileKey(row), row);
        }
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByType = DNAMSIDPActionUtil.getActionsByDocumentType();
        List<String> lines = new List<String>();
        for (FileChange change : changes) {
            if (change.kind != CHANGE_UNCHANGED) {
                continue;
            }
            AIReviewStageResult__c row = rowByKey.get(change.key());
            String documentType = change.baselineRow.DocumentType__c;
            DNAMSIDPWrapper.ActionConfig action = documentType == null ? null : actionByType.get(documentType.toLowerCase());
            if (row == null && action == null) {
                continue; // not extracted before and still not mapped
            }
            String reason = row == null ? 'now mapped to IDP action ' + action.developerName : extractionChangeReason(row, documentType, action);
            if (reason != null) {
                lines.add(change.elementName + ' / ' + change.title + ': extraction runs again (' + reason + ').');
            }
        }
        return lines;
    }

    /**
     * @description Rule lines when the files and extraction are unchanged: re-resolves every applicable rule with the
     *              baseline's consolidated extraction and compares the values and the rule set; recomputes the PIR inputs.
     * @param packageId DNAMS_Package__c id
     * @param baseline  Baseline run (with ConsolidatedExtractionJSON__c)
     * @return          Human-readable lines (empty when nothing changed)
     **/
    private static List<String> rulePreview(Id packageId, AI_Package_Review_Run__c baseline) {
        List<String> lines = new List<String>();
        Map<String, AIReviewStageResult__c> baselineByRule = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : stageRows(baseline.Id, DNAMSPipelineConstants.STAGE_RULE_VALIDATION)) {
            baselineByRule.put(ruleKey(row), row);
        }
        try {
            DNAMS_Package__c pkg = [
                SELECT Id, Type__c, PIR_Linked__c, PIR_Cleared__c, PIR_Bypass_Acknowledged__c
                FROM DNAMS_Package__c
                WHERE Id = :packageId
                WITH SYSTEM_MODE
            ];
            Map<String, String> sourceByRule = new Map<String, String>();
            Map<String, String> referenceByRule = new Map<String, String>();
            resolveRules(pkg, baseline.ConsolidatedExtractionJSON__c, sourceByRule, referenceByRule);
            List<String> changedRules = new List<String>();
            for (String ruleId : sourceByRule.keySet()) {
                AIReviewStageResult__c row = baselineByRule.remove(ruleId);
                if (row == null) {
                    changedRules.add(ruleId + ' (now applies)');
                } else if (!sameValue(row.SourceValue__c, sourceByRule.get(ruleId)) || !sameValue(row.ReferenceValue__c, referenceByRule.get(ruleId))) {
                    changedRules.add(ruleId);
                }
            }
            AIReviewStageResult__c pirRow = baselineByRule.remove(DNAMSPipelineConstants.PIR_RULE_ID);
            for (String ruleId : baselineByRule.keySet()) {
                changedRules.add(ruleId + ' (no longer applies)');
            }
            if (!changedRules.isEmpty()) {
                lines.add('Rule values changed: ' + String.join(changedRules, ', ') + '.');
            }
            if (pirRow == null || !sameValue(pirRow.SourceValue__c, pirSourceValue(pkg))) {
                lines.add('PIR status changed.');
            }
        } catch (Exception e) {
            // Exception to guideline: a rule that cannot be resolved here must not break the modal; treat it as a change
            lines.add('Rule values could not be compared (' + e.getMessage() + '); rules are checked again.');
        }
        return lines;
    }

    /**
     * @description Resolves the applicable rules the way DNAMSRuleValidationStarterQueueable does (element rules whose
     *              element is missing have no values).
     * @param pkg              Package with Type__c
     * @param consolidatedJson Baseline ConsolidatedExtractionJSON__c
     * @param sourceByRule     Filled: resolved source value per RuleId
     * @param referenceByRule  Filled: resolved reference value per RuleId
     **/
    private static void resolveRules(DNAMS_Package__c pkg, String consolidatedJson, Map<String, String> sourceByRule, Map<String, String> referenceByRule) {
        Set<String> elementTypes = new Set<String>();
        for (DNAMS_Package_Element__c element : [
            SELECT Name, Element_Type__r.Name FROM DNAMS_Package_Element__c WHERE Package__c = :pkg.Id WITH SYSTEM_MODE
        ]) {
            elementTypes.add((element.Element_Type__r?.Name ?? element.Name).trim().toLowerCase());
        }
        DNAMSRuleEvaluator evaluator = new DNAMSRuleEvaluator(pkg.Id, consolidatedJson);
        for (DNAMSRule__mdt rule : DNAMSRuleUtil.getRules()) {
            if (!DNAMSRuleUtil.appliesTo(rule, pkg.Type__c)) {
                continue;
            }
            Boolean isPackageRule = rule.RuleAppliedTo__c == DNAMSPipelineConstants.APPLIED_TO_PACKAGE;
            if (!isPackageRule && !elementTypes.contains((rule.RelativeElementType__c ?? '').trim().toLowerCase())) {
                sourceByRule.put(rule.DeveloperName, null);
                referenceByRule.put(rule.DeveloperName, null);
                continue;
            }
            DNAMSRuleEvaluator.Outcome outcome = evaluator.evaluate(rule);
            sourceByRule.put(rule.DeveloperName, outcome.sourceValue?.left(VALUE_LENGTH));
            referenceByRule.put(rule.DeveloperName, outcome.referenceValue?.left(VALUE_LENGTH));
        }
    }

    /**
     * @description PIR row SourceValue__c as DNAMSRuleValidationStarterQueueable.pirRow writes it.
     * @param pkg Package with the PIR fields
     * @return    "Linked: x, Cleared: y, Bypass acknowledged: z"
     **/
    @TestVisible
    private static String pirSourceValue(DNAMS_Package__c pkg) {
        return 'Linked: ' + pkg.PIR_Linked__c + ', Cleared: ' + pkg.PIR_Cleared__c + ', Bypass acknowledged: ' + pkg.PIR_Bypass_Acknowledged__c;
    }

    // ------------------------------------------------------------------ Helpers

    /**
     * @description Rows of several runs and stages with all CLONE_FIELDS, oldest first.
     * @param runIds Run ids (nulls ignored)
     * @param stages Stage__c values
     * @return       Rows
     **/
    private static List<AIReviewStageResult__c> stageRows(Set<Id> runIds, Set<String> stages) {
        Set<Id> ids = new Set<Id>(runIds);
        ids.remove(null);
        if (ids.isEmpty()) {
            return new List<AIReviewStageResult__c>();
        }
        return Database.queryWithBinds(
            'SELECT Id, Name, ReviewRun__c, ReusedFromResult__c, ' + String.join(CLONE_FIELDS, ', ') +
                ' FROM AIReviewStageResult__c WHERE ReviewRun__c IN :runIds AND Stage__c IN :stages ORDER BY CreatedDate, Name',
            new Map<String, Object>{ 'runIds' => ids, 'stages' => stages },
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * @description Single-stage overload of stageRows.
     * @param runIds Run ids
     * @param stage  Stage__c value
     * @return       Rows
     **/
    private static List<AIReviewStageResult__c> stageRows(Set<Id> runIds, String stage) {
        return stageRows(runIds, new Set<String>{ stage });
    }

    /**
     * @description Text id to Id (15 or 18 characters); null for blank or invalid text.
     * @param value Id text
     * @return      The Id, or null
     **/
    private static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (StringException invalidId) {
            // Handled: a malformed id simply never matches a current file
            return null;
        }
    }

    /**
     * @description Case-insensitive, trimmed comparison of document types (blank equals null).
     * @param left  First value
     * @param right Second value
     * @return      True when equal
     **/
    private static Boolean sameText(String left, String right) {
        return (left ?? '').trim().equalsIgnoreCase((right ?? '').trim());
    }

    /**
     * @description Case-sensitive comparison of stored rule values, truncated like the stored field (blank equals null).
     * @param stored   Stored value
     * @param resolved Freshly resolved value
     * @return         True when equal
     **/
    private static Boolean sameValue(String stored, String resolved) {
        return (stored ?? '').equals((resolved?.left(VALUE_LENGTH)) ?? '');
    }

    // ------------------------------------------------------------------ Wrappers

    /**
     * @description One current or removed file compared with the baseline.
     **/
    public class FileChange {
        public String kind;
        public Id elementId;
        public String elementName;
        public Id contentDocumentId;
        public Id contentVersionId;
        public String title;
        /** Baseline Classification row with the same key (Unchanged / Unfinished) or the removed file's row; else null. */
        public AIReviewStageResult__c baselineRow;

        /**
         * @description fileKey of this file.
         * @return      "elementId|contentDocumentId|contentVersionId"
         **/
        public String key() {
            return fileKey(elementId, contentDocumentId, contentVersionId);
        }

        /**
         * @description Short reason for ChangeSummary__c and the preview, e.g. "Org Chart / chart.pdf: new version".
         * @param baselineName Baseline run Name
         * @return             The text
         **/
        public String describe(String baselineName) {
            String what;
            if (kind == CHANGE_NEW_VERSION) {
                what = 'new version';
            } else if (kind == CHANGE_ADDED) {
                what = 'new file (no result in ' + baselineName + ')';
            } else if (kind == CHANGE_REMOVED) {
                what = 'removed';
            } else if (kind == CHANGE_UNFINISHED) {
                what = 'did not finish in ' + baselineName;
            } else {
                what = 'unchanged';
            }
            return elementName + ' / ' + title + ': ' + what;
        }
    }

    /**
     * @description Result of preview for the Re-run modal.
     **/
    public class Preview {
        @AuraEnabled
        public Boolean hasBaseline = false;
        @AuraEnabled
        public Boolean hasChanges = false;
        @AuraEnabled
        public Id baselineRunId;
        @AuraEnabled
        public String baselineRunName;
        /** Multi-line text for the modal: "Compared with RUN-x:\n- ..." or the "Nothing has changed" message. */
        @AuraEnabled
        public String text;
        @AuraEnabled
        public List<String> lines = new List<String>();
        public List<FileChange> fileChanges = new List<FileChange>();
    }
}
