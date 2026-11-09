/**
 * @description     Read-only data for the Package record page components: dnamsPackageAiSummary (structured AI
 *                  summary), dnamsElementProgressSummary (element and stage counts) and dnamsPackageDocuments (files
 *                  grouped by element). Runs with sharing, so users see only packages they can access.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-05
 * @last modified by Sachin Mondal
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-05   Sachin Mondal   Initial version
 **/
// Exception to guideline: the DNAMS_ prefix is the project's class naming standard for this module
@SuppressWarnings('PMD.ClassNamingConventions')
public with sharing class DNAMS_PackageInsightsController {
    private static final String STATUS_PASSED = 'Passed';
    private static final String STATUS_FAILED = 'Failed';
    private static final String STATUS_NOT_REVIEWED = 'Not Reviewed';
    private static final List<String> STAGES = new List<String>{ 'Classification', 'Extraction', 'Rule Validation' };
    private static final Map<String, Schema.SObjectField> STAGE_FIELDS = new Map<String, Schema.SObjectField>{
        'Classification' => DNAMS_Package_Element__c.Classification_Status__c,
        'Extraction' => DNAMS_Package_Element__c.Extraction_Status__c,
        'Rule Validation' => DNAMS_Package_Element__c.Rule_Validation_Status__c
    };
    // Business names shown to users (the stage keys and fields stay technical).
    @TestVisible
    private static final Map<String, String> STAGE_LABELS = new Map<String, String>{
        'Classification' => 'All Documents Present',
        'Extraction' => 'Document Reading',
        'Rule Validation' => 'Is Document Valid and Complete'
    };

    /**
     * @description The AI summary card.
     **/
    public class SummaryView {
        @AuraEnabled
        public String health;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String summaryJson;
        @AuraEnabled
        public String plainText;
        @AuraEnabled
        public String aiLabel;
        @AuraEnabled
        public String runName;
        @AuraEnabled
        public Id runId;
        @AuraEnabled
        public String runStatus;
        @AuraEnabled
        public Datetime runEndedAt;
        @AuraEnabled
        public Decimal passRate;
    }

    /**
     * @description Counts for one stage.
     **/
    public class StageCount {
        @AuraEnabled
        public String stage;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public Integer passed = 0;
        @AuraEnabled
        public Integer failed = 0;
        @AuraEnabled
        public Integer notRun = 0;
    }

    /**
     * @description The Element Progress overview.
     **/
    public class ProgressView {
        @AuraEnabled
        public Integer total = 0;
        @AuraEnabled
        public Integer required = 0;
        @AuraEnabled
        public Integer withDocuments = 0;
        @AuraEnabled
        public Integer passed = 0;
        @AuraEnabled
        public Integer failed = 0;
        @AuraEnabled
        public Integer notReviewed = 0;
        @AuraEnabled
        public List<StageCount> stages = new List<StageCount>();
        @AuraEnabled
        public Decimal passRate;
        @AuraEnabled
        public String runName;
    }

    /**
     * @description One file on an element.
     **/
    public class FileView {
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String extension;
        @AuraEnabled
        public Integer size;
        @AuraEnabled
        public Datetime uploadedAt;
        @AuraEnabled
        public String uploadedBy;
        @AuraEnabled
        public String classifiedAs;
        @AuraEnabled
        public String classificationStatus;
        @AuraEnabled
        public String confidence;
    }

    /**
     * @description One element and its files.
     **/
    public class ElementFiles {
        @AuraEnabled
        public Id elementId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Boolean required;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public List<FileView> files = new List<FileView>();
    }

    /**
     * @description The package's structured AI summary and its latest run.
     * @param packageId DNAMS_Package__c id
     * @return          The summary view
     **/
    @AuraEnabled(cacheable=true)
    public static SummaryView getAiSummary(Id packageId) {
        DNAMS_Package__c pkg = [
            SELECT Id, Health__c, Status__c, AI_Narrative__c, AI_Narrative_JSON__c
            FROM DNAMS_Package__c
            WHERE Id = :packageId
        ];
        SummaryView view = new SummaryView();
        view.health = pkg.Health__c;
        view.status = pkg.Status__c;
        view.summaryJson = pkg.AI_Narrative_JSON__c;
        view.plainText = pkg.AI_Narrative__c;
        view.aiLabel = DNAMS_PackageNarrativeQueueable.AI_LABEL;
        AI_Package_Review_Run__c run = latestRun(packageId);
        if (run != null) {
            view.runId = run.Id;
            view.runName = run.Name;
            view.runStatus = run.Status__c;
            view.runEndedAt = run.Ended_At__c;
            view.passRate = run.RuleValidationPassRate__c;
        }
        return view;
    }

    /**
     * @description Element and stage counts for the Element Progress tab.
     * @param packageId DNAMS_Package__c id
     * @return          The progress view
     **/
    @AuraEnabled(cacheable=true)
    public static ProgressView getElementProgress(Id packageId) {
        ProgressView view = new ProgressView();
        Map<String, StageCount> byStage = new Map<String, StageCount>();
        for (String stage : STAGES) {
            StageCount count = new StageCount();
            count.stage = stage;
            count.label = STAGE_LABELS.get(stage);
            byStage.put(stage, count);
            view.stages.add(count);
        }
        Map<Id, DNAMS_Package_Element__c> elements = elementsOf(packageId);
        Set<Id> withFiles = new Set<Id>();
        for (ContentDocumentLink link : linksOf(elements.keySet())) {
            withFiles.add(link.LinkedEntityId);
        }
        for (DNAMS_Package_Element__c element : elements.values()) {
            view.total++;
            view.required += element.Is_Required__c ? 1 : 0;
            view.withDocuments += withFiles.contains(element.Id) ? 1 : 0;
            String status = overallStatus(element);
            if (status == STATUS_PASSED) {
                view.passed++;
            } else if (status == STATUS_FAILED) {
                view.failed++;
            } else {
                view.notReviewed++;
            }
            for (String stage : STAGES) {
                count(byStage.get(stage), (String) element.get(STAGE_FIELDS.get(stage)));
            }
        }
        AI_Package_Review_Run__c run = latestRun(packageId);
        if (run != null) {
            view.passRate = run.RuleValidationPassRate__c;
            view.runName = run.Name;
        }
        return view;
    }

    /**
     * @description Files grouped by element: every element that is required or has files, in sort order.
     * @param packageId DNAMS_Package__c id
     * @return          Elements with their files (latest version details)
     **/
    @AuraEnabled(cacheable=true)
    public static List<ElementFiles> getDocuments(Id packageId) {
        Map<Id, DNAMS_Package_Element__c> elements = elementsOf(packageId);
        Map<Id, List<ContentDocumentLink>> linksByElement = new Map<Id, List<ContentDocumentLink>>();
        Set<Id> versionIds = new Set<Id>();
        for (ContentDocumentLink link : linksOf(elements.keySet())) {
            if (!linksByElement.containsKey(link.LinkedEntityId)) {
                linksByElement.put(link.LinkedEntityId, new List<ContentDocumentLink>());
            }
            linksByElement.get(link.LinkedEntityId).add(link);
            versionIds.add(link.ContentDocument.LatestPublishedVersionId);
        }
        Map<Id, ContentVersion> versions = new Map<Id, ContentVersion>(
            versionIds.isEmpty()
                ? new List<ContentVersion>()
                : [
                      SELECT Id, DocumentClassifiedAs__c, Classification_Status__c, Classification_Confidence__c, CreatedBy.Name
                      FROM ContentVersion
                      WHERE Id IN :versionIds
                  ]
        );
        List<ElementFiles> result = new List<ElementFiles>();
        for (DNAMS_Package_Element__c element : elements.values()) {
            List<ContentDocumentLink> links = linksByElement.get(element.Id) ?? new List<ContentDocumentLink>();
            if (!element.Is_Required__c && links.isEmpty()) {
                continue;
            }
            ElementFiles elementGroup = new ElementFiles();
            elementGroup.elementId = element.Id;
            elementGroup.name = element.Name;
            elementGroup.required = element.Is_Required__c;
            elementGroup.status = overallStatus(element);
            for (ContentDocumentLink link : links) {
                ContentVersion version = versions.get(link.ContentDocument.LatestPublishedVersionId);
                FileView file = new FileView();
                file.contentDocumentId = link.ContentDocumentId;
                file.title = link.ContentDocument.Title;
                file.extension = link.ContentDocument.FileExtension;
                file.size = link.ContentDocument.ContentSize;
                file.uploadedAt = link.ContentDocument.CreatedDate;
                file.uploadedBy = version?.CreatedBy?.Name;
                file.classifiedAs = version?.DocumentClassifiedAs__c;
                file.classificationStatus = version?.Classification_Status__c;
                file.confidence = version?.Classification_Confidence__c;
                elementGroup.files.add(file);
            }
            result.add(elementGroup);
        }
        return result;
    }

    /**
     * @description Pass/fail element status from its stage results.
     * @param element The element with its stage status fields
     * @return        Failed (any stage failed or needs review), Passed (at least one stage passed) or Not Reviewed
     **/
    @TestVisible
    private static String overallStatus(DNAMS_Package_Element__c element) {
        Boolean anyPassed = false;
        for (String stage : STAGES) {
            String status = (String) element.get(STAGE_FIELDS.get(stage));
            if (status == 'Failed' || status == 'Needs Review') {
                return STATUS_FAILED;
            }
            anyPassed = anyPassed || status == 'Passed';
        }
        return anyPassed ? STATUS_PASSED : STATUS_NOT_REVIEWED;
    }

    // Pass/fail only: Needs Review counts as failed; blank, In Progress and Not Applicable count as not run.
    private static void count(StageCount stage, String status) {
        if (status == 'Passed') {
            stage.passed++;
        } else if (status == 'Failed' || status == 'Needs Review') {
            stage.failed++;
        } else {
            stage.notRun++;
        }
    }

    private static Map<Id, DNAMS_Package_Element__c> elementsOf(Id packageId) {
        return new Map<Id, DNAMS_Package_Element__c>([
            SELECT Id, Name, Is_Required__c, Classification_Status__c, Extraction_Status__c, Rule_Validation_Status__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :packageId
            ORDER BY Sort_Order__c ASC NULLS LAST, Name
        ]);
    }

    private static List<ContentDocumentLink> linksOf(Set<Id> elementIds) {
        if (elementIds.isEmpty()) {
            return new List<ContentDocumentLink>();
        }
        return [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension,
                ContentDocument.ContentSize, ContentDocument.CreatedDate, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :elementIds
            ORDER BY ContentDocument.CreatedDate DESC
        ];
    }

    private static AI_Package_Review_Run__c latestRun(Id packageId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, Name, Status__c, Ended_At__c, RuleValidationPassRate__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c != 'Discarded'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return runs.isEmpty() ? null : runs[0];
    }
}
