/**
 * @description     Per-document stage rows (AIReviewStageResult__c) for the pipeline stages that do not own their rows
 *                  end to end. Classification: one row per file per run with the AI answer (type, confidence, reasoning,
 *                  raw response) and the deterministic outcome, so every run keeps its own classification history.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-04
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-04   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSStageResultHelper {
    private static final Integer TEXT_LENGTH = 255;
    private static final Integer RAW_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.RawStageResponseJSON__c.getLength();
    private static final Integer LONG_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.Reasoning__c.getLength();

    /**
     * @description Builds one Classification row per classified file of an element (not inserted).
     * @param runId   Review run id
     * @param element Package element (Id, Name, Element_Type__r.Name)
     * @param results The element's file results from DNAMS_DocumentClassificationBatch
     * @return        Rows to insert
     **/
    public static List<AIReviewStageResult__c> classificationRows(
        Id runId,
        DNAMS_Package_Element__c element,
        List<DNAMS_DocumentClassificationBatch.FileResult> results
    ) {
        List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        for (DNAMS_DocumentClassificationBatch.FileResult result : results ?? new List<DNAMS_DocumentClassificationBatch.FileResult>()) {
            Boolean isError = result.outcome == DNAMS_DocumentClassificationBatch.OUTCOME_ERROR;
            rows.add(new AIReviewStageResult__c(
                ReviewRun__c = runId,
                PackageElement__c = element.Id,
                Stage__c = DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION,
                ElementType__c = (element.Element_Type__r?.Name ?? element.Name)?.left(TEXT_LENGTH),
                DocumentTitle__c = result.title?.left(TEXT_LENGTH),
                ContentDocumentId__c = result.contentDocumentId,
                ContentVersionId__c = result.versionId,
                DocumentType__c = result.documentType?.left(TEXT_LENGTH),
                Confidence__c = result.confidence,
                Outcome__c = result.outcome,
                Reasoning__c = isError ? null : result.reasoning?.left(LONG_LENGTH),
                RawStageResponseJSON__c = result.rawResponse?.left(RAW_LENGTH),
                ProcessingStatus__c = isError ? DNAMSPipelineConstants.ROW_ERROR : DNAMSPipelineConstants.ROW_COMPLETED,
                ProcessingErrorDetails__c = isError ? result.reasoning?.left(LONG_LENGTH) : null,
                ProcessingCompletedAt__c = System.now()
            ));
        }
        return rows;
    }

    /**
     * @description Inserts stage rows with partial success, so one bad row never blocks the stage's other results.
     * @param rows Rows built by this helper
     **/
    public static void insertRows(List<AIReviewStageResult__c> rows) {
        if (rows == null || rows.isEmpty()) {
            return;
        }
        Database.insert(rows, false, AccessLevel.SYSTEM_MODE);
    }
}
