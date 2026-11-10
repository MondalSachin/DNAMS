/**
 * @description     Diagram steps 12-15: classifies the files of each In Progress element (step 13), stamps each file's
 *                  latest ContentVersion (step 14) and sets the element's Classification stage, then hands over to
 *                  completion (step 15 -> 16).
 *                  Confidence bands come from DNAMS_Pipeline_Setting__mdt: >= Min Auto Accept -> accepted;
 *                  >= Min Accepted -> Needs Review (AI unsure); below -> unclassified.
 *                  A confident answer matches only when its document_type is one of the element's accepted types
 *                  (DNAMSElementDocumentType__mdt, else the element type name); otherwise the file is wrong.
 *                  Element result: Failed if any file is wrong, unclassified or errored; else Needs Review if any file
 *                  is unsure; else Passed. A required document type (DNAMSElementDocumentType__mdt.IsRequired__c) with
 *                  no file classified as it (confident match or unsure) also fails the element, which stops the run at
 *                  classification. Each execute re-checks the run Status and stops if the run was cancelled.
 *                  Changes Only runs (DNAMSRunChangeDetector.baselineRunIdFor not null): a file whose key
 *                  (element|document|version) has a finished Classification row in the baseline makes no model call; the
 *                  baseline row is copied (cloneForReuse, ReusedFromResult__c set) and its stored model answer is applied
 *                  again with the current confidence settings and accepted types, so the element result is computed
 *                  from all its files (reused + freshly classified) exactly like a full run. finish() appends the
 *                  Classification line to the run's ChangeSummary__c.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Re-run changes only: reuse unchanged files' classification
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  PMD clean-up: ApexDoc, fewer parameters, complexity split into helpers
 * 1.1   2026-11-05   Sachin Mondal   Required document types fail the element when missing
 * 1.2   2026-11-10   Abhishek Dutta  Re-run changes only: reuse unchanged files' classification
 **/
// Exception to guideline: without sharing because the system pipeline must read all package elements and files regardless of ownership
// Class name kept: renaming would break the callers, tests and metadata that reference it
@SuppressWarnings('PMD.ClassNamingConventions')
public without sharing class DNAMS_DocumentClassificationBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    public static final String UNCLASSIFIED = 'Unclassified';
    // Per-file outcomes.
    public static final String OUTCOME_MATCH = 'Match';
    public static final String OUTCOME_WRONG = 'Wrong';
    public static final String OUTCOME_UNSURE = 'Unsure';
    public static final String OUTCOME_UNCLASSIFIED = 'Unclassified';
    public static final String OUTCOME_ERROR = 'Error';
    private static final List<String> CONFIDENCE_ORDER = new List<String>{ 'LOW', 'MODERATE', 'FULLY' };
    private static final String CLASS_NAME = DNAMS_DocumentClassificationBatch.class.getName();

    @TestVisible
    private static DNAMS_DocumentClassifier classifier = new DNAMS_EinsteinDocumentClassifier();

    private Id runId;
    private Id packageId;

    /**
     * @description Creates the batch for one run.
     * @param runId     Review run being classified
     * @param packageId Package whose In Progress elements are classified
     **/
    public DNAMS_DocumentClassificationBatch(Id runId, Id packageId) {
        this.runId = runId;
        this.packageId = packageId;
    }

    /**
     * @description Selects the package's elements whose Classification stage is In Progress.
     * @param context Batch context
     * @return        Query locator over DNAMS_Package_Element__c
     **/
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator(
            [
                SELECT Id, Name, Element_Type__r.Name
                FROM DNAMS_Package_Element__c
                WHERE Package__c = :packageId AND Classification_Status__c = :DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS
            ]
        );
    }

    /**
     * @description Classifies every file of the chunk's elements, then saves element results and file stamps.
     * @param context  Batch context
     * @param elements In Progress package elements
     **/
    public void execute(Database.BatchableContext context, List<DNAMS_Package_Element__c> elements) {
        if (!DNAMS_PackageReviewPipelineService.isRunning(runId)) {
            return; // cancelled or failed; finish() settles the run
        }
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_PackageReviewPipelineService.settings();
        Integer maxAttempts = Math.max(1, setting.Max_Attempts__c.intValue());
        Map<Id, List<FileResult>> resultsByElement = new Map<Id, List<FileResult>>();
        Map<Id, DNAMS_Package_Element__c> elementsById = new Map<Id, DNAMS_Package_Element__c>(elements);
        Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType = DNAMSElementDocumentTypeUtil.getByElementType();
        for (DNAMS_Package_Element__c element : elements) {
            resultsByElement.put(element.Id, new List<FileResult>());
        }
        // Changes Only: finished baseline rows by file key (empty for an All run)
        Id baselineRunId = DNAMSRunChangeDetector.baselineRunIdFor(runId);
        Map<String, AIReviewStageResult__c> reusableByKey = baselineRunId == null
            ? new Map<String, AIReviewStageResult__c>()
            : DNAMSRunChangeDetector.reusableClassificationRows(baselineRunId);

        // All model calls first, then DML: callouts are not allowed after uncommitted work.
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :resultsByElement.keySet()
            ORDER BY ContentDocument.CreatedDate
        ]) {
            String extension = link.ContentDocument.FileExtension;
            FileResult result = new FileResult();
            result.title = link.ContentDocument.Title + (String.isBlank(extension) ? '' : '.' + extension);
            result.versionId = link.ContentDocument.LatestPublishedVersionId;
            result.contentDocumentId = link.ContentDocumentId;
            setAccepted(result, elementsById.get(link.LinkedEntityId), rowsByType);
            AIReviewStageResult__c baselineRow = reusableByKey.get(
                DNAMSRunChangeDetector.fileKey(link.LinkedEntityId, link.ContentDocumentId, result.versionId)
            );
            if (baselineRow == null) {
                classifyWithRetry(result, link, maxAttempts);
            } else {
                reuseResult(result, baselineRow);
            }
            resultsByElement.get(link.LinkedEntityId).add(result);
        }

        List<DNAMS_Package_Element__c> updates = new List<DNAMS_Package_Element__c>();
        List<ContentVersion> stamps = new List<ContentVersion>();
        List<AIReviewStageResult__c> stageRows = new List<AIReviewStageResult__c>();
        for (DNAMS_Package_Element__c element : elements) {
            List<FileResult> results = resultsByElement.get(element.Id);
            updates.add(elementResult(element, results, requiredTypes(element, rowsByType)));
            // One Classification row per file per run (per-document history for every stage)
            stageRows.addAll(DNAMSStageResultHelper.classificationRows(runId, element, results));
            for (FileResult result : results) {
                if (result.versionId != null) {
                    stamps.add(
                        new ContentVersion(
                            Id = result.versionId,
                            DocumentClassifiedAs__c = result.documentType,
                            Classification_Status__c = result.fileStatus(),
                            Classification_Confidence__c = result.confidence,
                            Classified_At__c = result.reusedFrom?.ProcessingCompletedAt__c ?? System.now()
                        )
                    );
                }
            }
        }
        update updates;
        Database.update(stamps, false); // a stamp failure must not lose the element results
        DNAMSStageResultHelper.insertRows(stageRows);
    }

    /**
     * @description Hands over to completion (step 15 -> 16); a failure there fails the run.
     * @param context Batch context
     **/
    public void finish(Database.BatchableContext context) {
        appendChangeSummary(runId, packageId);
        try {
            DNAMS_PackageReviewPipelineService.completeClassification(runId);
        } catch (Exception e) {
            DNAMS_PackageReviewPipelineService.failRun(runId, e);
        }
    }

    // ------------------------------------------------------------------ Re-run changes only

    /**
     * @description On a Changes Only run, appends "Classification: N reused, M re-run (reasons)" to the run's
     *              ChangeSummary__c. Counts come from this run's Classification rows (ReusedFromResult__c set or not);
     *              reasons are every file that was not reused (new version, new file, did not finish) and every removed
     *              file. Does nothing for an All run. A failure is logged and never stops the run.
     * @param runId     Review run
     * @param packageId Package of the run
     **/
    public static void appendChangeSummary(Id runId, Id packageId) {
        try {
            Id baselineRunId = DNAMSRunChangeDetector.baselineRunIdFor(runId);
            if (baselineRunId == null) {
                return;
            }
            String baselineName = [SELECT Name FROM AI_Package_Review_Run__c WHERE Id = :baselineRunId WITH SYSTEM_MODE].Name;
            Integer reused = 0;
            Integer rerun = 0;
            for (AIReviewStageResult__c row : [
                SELECT ReusedFromResult__c
                FROM AIReviewStageResult__c
                WHERE ReviewRun__c = :runId AND Stage__c = :DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION
                WITH SYSTEM_MODE
            ]) {
                if (row.ReusedFromResult__c == null) {
                    rerun++;
                } else {
                    reused++;
                }
            }
            List<String> reasons = new List<String>();
            for (DNAMSRunChangeDetector.FileChange change : DNAMSRunChangeDetector.fileChanges(packageId, baselineRunId)) {
                if (change.kind != DNAMSRunChangeDetector.CHANGE_UNCHANGED) {
                    reasons.add(change.describe(baselineName));
                }
            }
            DNAMSRunChangeDetector.appendChangeSummary(
                runId,
                DNAMSRunChangeDetector.SUMMARY_CLASSIFICATION,
                DNAMSRunChangeDetector.stageLine(reused, rerun, reasons)
            );
        } catch (Exception e) {
            // Handled: the change summary is informational, so it is logged and the classification still completes
            DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
            detail.runId = runId;
            detail.stage = DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION;
            detail.errorType = DNAMSPipelineConstants.ERROR_PROCESSING;
            detail.sourceClass = CLASS_NAME;
            detail.severity = DNAMSPipelineConstants.SEVERITY_WARNING;
            detail.message = 'Change summary not written: ' + e.getTypeName() + ': ' + e.getMessage();
            DNAMSErrorLogHelper.insertLogs(new List<AIReviewErrorLog__c>{ DNAMSErrorLogHelper.buildLog(detail) });
        }
    }

    /**
     * @description Fills a file result from a finished baseline row instead of calling the model. The stored model
     *              answer is applied again with the current confidence settings and accepted document types (the same
     *              deterministic step a fresh answer goes through); when it cannot be read, the stored result is kept.
     * @param result      File result to fill (title, ids and accepted types already set)
     * @param baselineRow Finished Classification row of the baseline with the same file key
     **/
    @TestVisible
    private static void reuseResult(FileResult result, AIReviewStageResult__c baselineRow) {
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_PackageReviewPipelineService.settings();
        result.reusedFrom = baselineRow;
        result.rawResponse = baselineRow.RawStageResponseJSON__c;
        try {
            applyResult(result, baselineRow.RawStageResponseJSON__c, setting.Min_Accepted_Confidence__c, setting.Min_Auto_Accept_Confidence__c);
        } catch (Exception unreadable) {
            // Handled: no readable stored answer (blank or truncated); keep the result the baseline recorded
            result.documentType = baselineRow.DocumentType__c;
            result.confidence = baselineRow.Confidence__c;
            result.reasoning = baselineRow.Reasoning__c;
            result.outcome = baselineRow.Outcome__c;
        }
    }

    // ------------------------------------------------------------------ per file

    /**
     * @description Calls the classifier up to maxAttempts times; after the last failure the file is an Error.
     * @param result      File result to fill
     * @param link        File link with ContentDocumentId and LinkedEntityId (the element)
     * @param maxAttempts Attempts allowed (at least 1)
     **/
    private static void classifyWithRetry(FileResult result, ContentDocumentLink link, Integer maxAttempts) {
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_PackageReviewPipelineService.settings();
        String lastError;
        for (Integer attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                String raw = classifier.classify(setting.Prompt_Template__c, link.ContentDocumentId, link.LinkedEntityId);
                result.rawResponse = raw;
                applyResult(result, raw, setting.Min_Accepted_Confidence__c, setting.Min_Auto_Accept_Confidence__c);
                return;
            } catch (Exception e) {
                lastError = e.getTypeName() + ': ' + e.getMessage();
            }
        }
        result.outcome = OUTCOME_ERROR;
        result.reasoning = lastError?.left(1000);
    }

    /**
     * @description Parses {"matches_expected", "document_type", "confidence", "reasoning"} into the file result.
     * @param result               File result to fill
     * @param raw                  Raw classifier output
     * @param minConfidence        Lowest confidence still treated as classified
     * @param autoAcceptConfidence Lowest confidence accepted without review (FULLY when null)
     * @throws DNAMS_PackageReviewPipelineService.PipelineException on malformed output
     **/
    // Four parameters kept: @TestVisible signature used by tests
    @SuppressWarnings('PMD.ExcessiveParameterList')
    @TestVisible
    private static void applyResult(FileResult result, String raw, String minConfidence, String autoAcceptConfidence) {
        String json = raw.trim().removeStart('```json').removeStart('```').removeEnd('```').trim();
        Map<String, Object> parsed = (Map<String, Object>) System.JSON.deserializeUntyped(json);
        // matches_expected is advisory; Apex decides from document_type against the accepted list (see FileResult.accepts).
        String documentType = (String) parsed.get('document_type');
        String confidence = ((String) parsed.get('confidence'))?.toUpperCase();
        if (String.isBlank(documentType) || !CONFIDENCE_ORDER.contains(confidence)) {
            throw new DNAMS_PackageReviewPipelineService.PipelineException('Unexpected classifier output: ' + raw.left(500));
        }
        Integer level = CONFIDENCE_ORDER.indexOf(confidence);
        result.documentType = documentType.left(255);
        result.confidence = confidence;
        result.reasoning = ((String) parsed.get('reasoning'))?.left(1000);
        if (level < CONFIDENCE_ORDER.indexOf(minConfidence) || documentType.equalsIgnoreCase(UNCLASSIFIED)) {
            result.outcome = OUTCOME_UNCLASSIFIED;
        } else if (level >= CONFIDENCE_ORDER.indexOf(autoAcceptConfidence ?? 'FULLY')) {
            result.outcome = result.accepts(documentType) ? OUTCOME_MATCH : OUTCOME_WRONG;
        } else {
            result.outcome = OUTCOME_UNSURE;
        }
    }

    /**
     * @description Sets the document types the element accepts: its DNAMSElementDocumentType__mdt rows, or the element
     *              type name (element Name when it has no type) when there are no rows.
     * @param result     File result to fill
     * @param element    Package element queried with Element_Type__r.Name
     * @param rowsByType Mapping rows keyed by lower-case element type name
     **/
    private static void setAccepted(FileResult result, DNAMS_Package_Element__c element, Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType) {
        String elementTypeName = typeName(element);
        List<DNAMSElementDocumentType__mdt> rows = rowsByType.get(elementTypeName.toLowerCase()) ??
            new List<DNAMSElementDocumentType__mdt>{ new DNAMSElementDocumentType__mdt(DocumentType__c = elementTypeName) };
        List<String> labels = new List<String>();
        for (DNAMSElementDocumentType__mdt row : rows) {
            labels.add(row.DocumentType__c.trim());
        }
        result.acceptedNames = DNAMSElementDocumentTypeUtil.getAcceptedNames(rows);
        result.acceptedLabel = String.join(labels, ' or ');
    }

    /**
     * @description Element type name used to look up the mapping rows (element Name when it has no type).
     * @param element Package element queried with Element_Type__r.Name
     * @return        Trimmed type name
     **/
    private static String typeName(DNAMS_Package_Element__c element) {
        return (element.Element_Type__r?.Name ?? element.Name).trim();
    }

    /**
     * @description Document types the element must contain (IsRequired__c mapping rows).
     * @param element    Package element queried with Element_Type__r.Name
     * @param rowsByType Mapping rows keyed by lower-case element type name
     * @return           Required document type names (empty when none)
     **/
    private static List<String> requiredTypes(DNAMS_Package_Element__c element, Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType) {
        return DNAMSElementDocumentTypeUtil.getRequiredNames(rowsByType.get(typeName(element).toLowerCase()));
    }

    // ------------------------------------------------------------------ per element

    /**
     * @description Element Classification result from its file results (see class description for the rules).
     * @param element Package element
     * @param results File results of the element
     * @return        Element update with status, classified types, lowest confidence, reasoning and narrative
     **/
    @TestVisible
    private static DNAMS_Package_Element__c elementResult(DNAMS_Package_Element__c element, List<FileResult> results) {
        return elementResult(element, results, new List<String>());
    }

    /**
     * @description Element Classification result, also failing the element for each required document type that no
     *              file was classified as (a confident match, or an unsure answer naming that type).
     * @param element       Package element
     * @param results       File results of the element
     * @param requiredTypes Document types the element must contain
     * @return              Element update with status, classified types, lowest confidence, reasoning and narrative
     **/
    @TestVisible
    private static DNAMS_Package_Element__c elementResult(DNAMS_Package_Element__c element, List<FileResult> results, List<String> requiredTypes) {
        String status = DNAMS_PackageReviewPipelineService.STAGE_PASSED;
        List<String> problems = new List<String>();
        Set<String> types = new Set<String>();
        List<String> reasoning = new List<String>();
        String lowest;
        for (FileResult result : results) {
            if (result.documentType != null) {
                types.add(result.documentType);
            }
            lowest = lowerConfidence(lowest, result.confidence);
            reasoning.add(result.title + ': ' + (result.reasoning ?? ''));
            String problem = result.problem(result.acceptedLabel);
            if (problem != null) {
                problems.add(problem);
                status = worseStatus(status, result.outcome);
            }
        }
        for (String requiredType : requiredTypes) {
            if (!isPresent(requiredType, results)) {
                problems.add(requiredType + ' missing. Upload a ' + requiredType + ' to ' + element.Name + '.');
                status = DNAMS_PackageReviewPipelineService.STAGE_FAILED;
            }
        }
        String narrative = null;
        if (!problems.isEmpty()) {
            narrative = problems[0] + (problems.size() > 1 ? ' (+' + (problems.size() - 1) + ' more)' : '');
        }
        return new DNAMS_Package_Element__c(
            Id = element.Id,
            Current_Stage__c = DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION,
            Classification_Status__c = status,
            Classified_As__c = String.join(new List<String>(types), '; ').left(255),
            Classification_Confidence__c = lowest,
            Classification_Reasoning__c = String.join(reasoning, '\n').left(32768),
            Element_Narrative__c = narrative?.left(255)
        );
    }

    /**
     * @description Whether any file was classified as the document type (confident match, or unsure naming it).
     * @param documentType Required document type
     * @param results      File results of the element
     * @return             True when present
     **/
    private static Boolean isPresent(String documentType, List<FileResult> results) {
        for (FileResult result : results) {
            Boolean counted = result.outcome == OUTCOME_MATCH || result.outcome == OUTCOME_UNSURE;
            if (counted && documentType.equalsIgnoreCase(result.documentType?.trim())) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description Lower of two confidence levels, ignoring a null candidate.
     * @param lowest    Lowest confidence so far (may be null)
     * @param candidate Confidence of the next file (may be null)
     * @return          The lower confidence
     **/
    private static String lowerConfidence(String lowest, String candidate) {
        if (candidate != null && (lowest == null || CONFIDENCE_ORDER.indexOf(candidate) < CONFIDENCE_ORDER.indexOf(lowest))) {
            return candidate;
        }
        return lowest;
    }

    /**
     * @description Element status after a file with a problem: unsure lowers Passed to Needs Review, anything else fails.
     * @param status  Element status so far
     * @param outcome Outcome of the problem file
     * @return        New element status
     **/
    private static String worseStatus(String status, String outcome) {
        if (outcome != OUTCOME_UNSURE) {
            return DNAMS_PackageReviewPipelineService.STAGE_FAILED;
        }
        return status == DNAMS_PackageReviewPipelineService.STAGE_PASSED ? DNAMS_PackageReviewPipelineService.STAGE_NEEDS_REVIEW : status;
    }

    /**
     * @description Classification outcome of one file.
     **/
    public class FileResult {
        public String title;
        public Id versionId;
        public String outcome;
        public String documentType;
        public String confidence;
        public String reasoning;
        public Id contentDocumentId;
        public String rawResponse;
        // Changes Only: the baseline row this result was reused from (null when classified in this run).
        public AIReviewStageResult__c reusedFrom;
        // Lower-case accepted document types and their "A or B" label for narratives.
        public Set<String> acceptedNames = new Set<String>();
        public String acceptedLabel;

        /**
         * @description Deterministic check of the AI answer against the element's accepted document types.
         * @param documentType Document type returned by the classifier (not blank)
         * @return             True when it is one of the accepted types (case-insensitive)
         **/
        public Boolean accepts(String documentType) {
            return acceptedNames.contains(documentType.trim().toLowerCase());
        }

        /**
         * @description Rule-based explanation for the element narrative; null when the file is fine.
         * @param expected Accepted document type label, e.g. "A or B"
         * @return         Problem text, or null
         **/
        public String problem(String expected) {
            if (outcome == OUTCOME_WRONG) {
                return 'Found ' + documentType + ' instead of ' + expected + '. Replace "' + title + '" with the correct document.';
            }
            if (outcome == OUTCOME_UNSURE) {
                return 'AI unsure "' + title + '" is ' + expected + ' (MODERATE). RMR to verify.';
            }
            if (outcome == OUTCOME_UNCLASSIFIED) {
                return 'Could not identify "' + title + '". Upload a clearer copy of the ' + expected + '.';
            }
            if (outcome == OUTCOME_ERROR) {
                return 'The AI could not read "' + title + '". Re-run the review or re-upload the file.';
            }
            return null;
        }

        /**
         * @description ContentVersion Classification_Status__c value for this file.
         * @return      Error, Unclassified, Needs Human Review or Classified
         **/
        public String fileStatus() {
            if (outcome == OUTCOME_ERROR) {
                return 'Error';
            }
            if (outcome == OUTCOME_UNCLASSIFIED) {
                return 'Unclassified';
            }
            return outcome == OUTCOME_UNSURE ? 'Needs Human Review' : 'Classified';
        }
    }
}