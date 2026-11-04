/**
 * Diagram steps 12-15: classifies the files of each In Progress element (step 13), stamps each file's latest
 * ContentVersion (step 14) and sets the element's Classification stage, then hands over to completion (step 15 -> 16).
 * Confidence bands come from DNAMS_Pipeline_Setting__mdt: >= Min Auto Accept -> accepted;
 * >= Min Accepted -> Needs Review (AI unsure); below -> unclassified.
 * Element result: Failed if any file is wrong, unclassified or errored; else Needs Review if any file is unsure;
 * else Passed. Each execute re-checks the run Status and stops if the run was cancelled.
 */
public without sharing class DNAMS_DocumentClassificationBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {
    public static final String UNCLASSIFIED = 'Unclassified';
    // Per-file outcomes.
    public static final String OUTCOME_MATCH = 'Match';
    public static final String OUTCOME_WRONG = 'Wrong';
    public static final String OUTCOME_UNSURE = 'Unsure';
    public static final String OUTCOME_UNCLASSIFIED = 'Unclassified';
    public static final String OUTCOME_ERROR = 'Error';
    private static final List<String> CONFIDENCE_ORDER = new List<String>{ 'LOW', 'MODERATE', 'FULLY' };

    @TestVisible
    private static DNAMS_DocumentClassifier classifier = new DNAMS_EinsteinDocumentClassifier();

    private final Id runId;
    private final Id packageId;

    public DNAMS_DocumentClassificationBatch(Id runId, Id packageId) {
        this.runId = runId;
        this.packageId = packageId;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator(
            [
                SELECT Id, Name
                FROM DNAMS_Package_Element__c
                WHERE Package__c = :packageId AND Classification_Status__c = :DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS
            ]
        );
    }

    public void execute(Database.BatchableContext context, List<DNAMS_Package_Element__c> elements) {
        if (!DNAMS_PackageReviewPipelineService.isRunning(runId)) {
            return; // cancelled or failed; finish() settles the run
        }
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_PackageReviewPipelineService.settings();
        Integer maxAttempts = Math.max(1, setting.Max_Attempts__c.intValue());
        Map<Id, List<FileResult>> resultsByElement = new Map<Id, List<FileResult>>();
        for (DNAMS_Package_Element__c element : elements) {
            resultsByElement.put(element.Id, new List<FileResult>());
        }

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
            classifyWithRetry(result, link.ContentDocumentId, link.LinkedEntityId, setting, maxAttempts);
            resultsByElement.get(link.LinkedEntityId).add(result);
        }

        List<DNAMS_Package_Element__c> updates = new List<DNAMS_Package_Element__c>();
        List<ContentVersion> stamps = new List<ContentVersion>();
        for (DNAMS_Package_Element__c element : elements) {
            List<FileResult> results = resultsByElement.get(element.Id);
            updates.add(elementResult(element, results));
            for (FileResult result : results) {
                if (result.versionId != null) {
                    stamps.add(
                        new ContentVersion(
                            Id = result.versionId,
                            DocumentClassifiedAs__c = result.documentType,
                            Classification_Status__c = result.fileStatus(),
                            Classification_Confidence__c = result.confidence,
                            Classified_At__c = System.now()
                        )
                    );
                }
            }
        }
        update updates;
        Database.update(stamps, false); // a stamp failure must not lose the element results
    }

    public void finish(Database.BatchableContext context) {
        try {
            DNAMS_PackageReviewPipelineService.completeClassification(runId);
        } catch (Exception e) {
            DNAMS_PackageReviewPipelineService.failRun(runId, e);
        }
    }

    // ------------------------------------------------------------------ per file

    private static void classifyWithRetry(FileResult result, Id contentDocumentId, Id elementId, DNAMS_Pipeline_Setting__mdt setting, Integer maxAttempts) {
        String lastError;
        for (Integer attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
                String raw = classifier.classify(setting.Prompt_Template__c, contentDocumentId, elementId);
                applyResult(result, raw, setting.Min_Accepted_Confidence__c, setting.Min_Auto_Accept_Confidence__c);
                return;
            } catch (Exception e) {
                lastError = e.getTypeName() + ': ' + e.getMessage();
            }
        }
        result.outcome = OUTCOME_ERROR;
        result.reasoning = lastError?.left(1000);
    }

    /** Parses {"matches_expected", "document_type", "confidence", "reasoning"}; throws on malformed output. */
    @TestVisible
    private static void applyResult(FileResult result, String raw, String minConfidence, String autoAcceptConfidence) {
        String json = raw.trim().removeStart('```json').removeStart('```').removeEnd('```').trim();
        Map<String, Object> parsed = (Map<String, Object>) System.JSON.deserializeUntyped(json);
        Boolean matches = parsed.get('matches_expected') == true;
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
            result.outcome = matches ? OUTCOME_MATCH : OUTCOME_WRONG;
        } else {
            result.outcome = OUTCOME_UNSURE;
        }
    }

    // ------------------------------------------------------------------ per element

    @TestVisible
    private static DNAMS_Package_Element__c elementResult(DNAMS_Package_Element__c element, List<FileResult> results) {
        String status = DNAMS_PackageReviewPipelineService.STAGE_PASSED;
        List<String> problems = new List<String>();
        Set<String> types = new Set<String>();
        List<String> reasoning = new List<String>();
        String lowest;
        for (FileResult result : results) {
            if (result.documentType != null) {
                types.add(result.documentType);
            }
            if (result.confidence != null && (lowest == null || CONFIDENCE_ORDER.indexOf(result.confidence) < CONFIDENCE_ORDER.indexOf(lowest))) {
                lowest = result.confidence;
            }
            reasoning.add(result.title + ': ' + (result.reasoning ?? ''));
            String problem = result.problem(element.Name);
            if (problem == null) {
                continue;
            }
            problems.add(problem);
            if (result.outcome == OUTCOME_UNSURE) {
                if (status == DNAMS_PackageReviewPipelineService.STAGE_PASSED) {
                    status = DNAMS_PackageReviewPipelineService.STAGE_NEEDS_REVIEW;
                }
            } else {
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

    public class FileResult {
        public String title;
        public Id versionId;
        public String outcome;
        public String documentType;
        public String confidence;
        public String reasoning;

        /** Rule-based explanation for the element narrative; null when the file is fine. */
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