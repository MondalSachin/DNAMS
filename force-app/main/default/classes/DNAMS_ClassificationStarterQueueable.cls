/**
 * @description     Diagram steps 7-10 and 12: for a Running run, resets the package's element stage results (8), marks
 *                  every element that has files as Classification In Progress (9-10) and starts
 *                  DNAMS_DocumentClassificationBatch over those elements (12). Elements without files are settled in
 *                  DNAMS_PackageReviewPipelineService.completeClassification. Each element with files gets
 *                  AcceptedDocumentTypes__c (the classifier prompt input) from DNAMSElementDocumentType__mdt.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details PMD clean-up: ApexDoc, run-failure finalizer
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  PMD clean-up: ApexDoc, run-failure finalizer
 **/
// Exception to guideline: without sharing because the system pipeline must reset all package elements regardless of ownership
// Class name kept: renaming would break the callers, tests and metadata that reference it
@SuppressWarnings('PMD.ClassNamingConventions')
public without sharing class DNAMS_ClassificationStarterQueueable implements Queueable {
    private static final String CLASS_NAME = DNAMS_ClassificationStarterQueueable.class.getName();

    private Id runId;

    /**
     * @description Creates the starter for one run.
     * @param runId AI_Package_Review_Run__c id
     **/
    public DNAMS_ClassificationStarterQueueable(Id runId) {
        this.runId = runId;
    }

    /**
     * @description Resets the elements and starts the classification batch, or completes directly when no element has files.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (context != null) { // null when execute is called directly rather than as a queued job
            System.attachFinalizer(new DNAMSExtractionStarterQueueable.RunFailureFinalizer(new Set<Id>{ runId }, CLASS_NAME));
        }
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
            // Pre-flight gate: every file must be an allowed type within the size limit before any AI step runs
            if (!DNAMSFilePreflightHelper.passesPreflight(run)) {
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

    /**
     * @description Clears the previous run's results.
     * @param packageId Package whose elements are reset
     * @return          How many elements have files to classify
     **/
    private static Integer resetElements(Id packageId) {
        Map<Id, DNAMS_Package_Element__c> elements = new Map<Id, DNAMS_Package_Element__c>(
            [SELECT Id, Name, Element_Type__r.Name, Element_Type__r.Identifying_Definition__c FROM DNAMS_Package_Element__c WHERE Package__c = :packageId]
        );
        Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType = DNAMSElementDocumentTypeUtil.getByElementType();
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
            element.AcceptedDocumentTypes__c = hasFiles ? acceptedTypesText(element, rowsByType) : null;
        }
        update elements.values();
        return withFiles.size();
    }

    /**
     * @description Prompt input listing the document types the element accepts (DNAMSElementDocumentType__mdt); without
     *              mapping rows, falls back to the element type name and its Identifying_Definition__c.
     * @param element    Package element queried with its Element_Type__r fields
     * @param rowsByType Mapping rows keyed by lower-case element type name
     * @return           Lines of "- <Document Type>: <instructions>"
     **/
    private static String acceptedTypesText(DNAMS_Package_Element__c element, Map<String, List<DNAMSElementDocumentType__mdt>> rowsByType) {
        String typeName = element.Element_Type__r?.Name ?? element.Name;
        String text = DNAMSElementDocumentTypeUtil.buildPromptText(rowsByType.get(typeName.trim().toLowerCase()));
        if (text != null) {
            return text;
        }
        String definition = element.Element_Type__r?.Identifying_Definition__c?.normalizeSpace();
        return '- ' + typeName + (String.isBlank(definition) ? '' : ': ' + definition);
    }
}