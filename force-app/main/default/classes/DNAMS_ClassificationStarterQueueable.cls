/**
 * Diagram steps 7-10 and 12: for a Running run, resets the package's element stage results (8), marks every element
 * that has files as Classification In Progress (9-10) and starts DNAMS_DocumentClassificationBatch over those
 * elements (12). Elements without files are settled in DNAMS_PackageReviewPipelineService.completeClassification.
 */
public without sharing class DNAMS_ClassificationStarterQueueable implements Queueable {
    private final Id runId;

    public DNAMS_ClassificationStarterQueueable(Id runId) {
        this.runId = runId;
    }

    public void execute(QueueableContext context) {
        try {
            AI_Package_Review_Run__c run = DNAMS_PackageReviewPipelineService.lockRun(runId);
            if (run == null) {
                return;
            }
            Integer withFiles = resetElements(run.Package__c);
            if (withFiles == 0) {
                DNAMS_PackageReviewPipelineService.completeClassification(runId);
                return;
            }
            run.Classification_Processing_Status__c = 'In Progress';
            run.Job_Id__c = Database.executeBatch(
                new DNAMS_DocumentClassificationBatch(runId, run.Package__c),
                DNAMS_PackageReviewPipelineService.settings().Batch_Size__c.intValue()
            );
            update run;
        } catch (Exception e) {
            DNAMS_PackageReviewPipelineService.failRun(runId, e);
        }
    }

    /** Clears the previous run's results; returns how many elements have files to classify. */
    private static Integer resetElements(Id packageId) {
        Map<Id, DNAMS_Package_Element__c> elements = new Map<Id, DNAMS_Package_Element__c>(
            [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c = :packageId]
        );
        Set<Id> withFiles = new Set<Id>();
        if (!elements.isEmpty()) {
            for (ContentDocumentLink link : [SELECT LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :elements.keySet()]) {
                withFiles.add(link.LinkedEntityId);
            }
        }
        for (DNAMS_Package_Element__c element : elements.values()) {
            Boolean hasFiles = withFiles.contains(element.Id);
            element.Current_Stage__c = hasFiles ? DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION : null;
            element.Classification_Status__c = hasFiles ? DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS : null;
            element.Extraction_Status__c = null;
            element.Rule_Validation_Status__c = null;
            element.Transmittal_Status__c = null;
            element.Element_Narrative__c = null;
            element.Classified_As__c = null;
            element.Classification_Confidence__c = null;
            element.Classification_Reasoning__c = null;
        }
        update elements.values();
        return withFiles.size();
    }
}