/**
 * @description     LLD page 5 steps [2]-[7]: starts extraction for a run that passed classification. Reads the files of
 *                  the Passed elements, maps each file's DocumentClassifiedAs__c to a DNAMSIDPAction__mdt, creates one
 *                  Pending AIReviewStageResult__c per mapped file and starts DNAMSExtractionSubmitBatch. Files without a
 *                  mapping set their element's Extraction_Status__c to Not Applicable.
 *                  One run is processed per transaction; further run ids are re-published as Start Extraction events
 *                  so each run gets its own limits and its completion can enqueue its own follow-up job.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
// Exception to guideline: without sharing because the system pipeline runs as the IDP integration user and must read all package files/records regardless of ownership
public without sharing class DNAMSExtractionStarterQueueable implements Queueable {
    private static final String CLASS_NAME = DNAMSExtractionStarterQueueable.class.getName();
    private static final Integer TITLE_LENGTH = Schema.SObjectType.AIReviewStageResult__c.fields.DocumentTitle__c.getLength();

    private Set<Id> runIds;

    /**
     * @description Creates the starter for the given runs.
     * @param runIds AI_Package_Review_Run__c ids whose classification passed
     **/
    public DNAMSExtractionStarterQueueable(Set<Id> runIds) {
        this.runIds = runIds == null ? new Set<Id>() : runIds;
    }

    /**
     * @description Starts extraction for the first run and re-publishes Start Extraction events for the others.
     * @param context Queueable context
     **/
    public void execute(QueueableContext context) {
        if (runIds.isEmpty()) {
            return;
        }
        List<Id> remainingIds = new List<Id>(runIds);
        Id runId = remainingIds.remove(0);
        if (context != null) { // null when execute is called directly rather than as a queued job
            System.attachFinalizer(new RunFailureFinalizer(new Set<Id>{ runId }, CLASS_NAME));
        }
        Savepoint savepoint = Database.setSavepoint();
        try {
            startRun(runId);
        } catch (Exception e) {
            Database.rollback(savepoint);
            DNAMSErrorLogHelper.logException(e, runId, CLASS_NAME);
        }
        republish(remainingIds);
    }

    /**
     * @description Steps [2]-[7] for one run. A run that is no longer Running (cancelled, failed, deleted) is skipped.
     * @param runId AI_Package_Review_Run__c id
     **/
    private static void startRun(Id runId) {
        // lockRun settles a Cancelling run and returns null for any run that is not Running
        AI_Package_Review_Run__c run = DNAMS_PackageReviewPipelineService.lockRun(runId);
        if (run == null) {
            return;
        }
        Map<Id, DNAMS_Package_Element__c> elementById = new Map<Id, DNAMS_Package_Element__c>(
            [
                SELECT Id, Element_Type__r.Name
                FROM DNAMS_Package_Element__c
                WHERE Package__c = :run.Package__c AND Classification_Status__c = :DNAMS_PackageReviewPipelineService.STAGE_PASSED
                WITH SYSTEM_MODE
            ]
        );
        StagePlan plan = buildPlan(run.Id, elementById);
        Database.insert(plan.rows, true, AccessLevel.SYSTEM_MODE);
        Database.update(plan.elementUpdates(), true, AccessLevel.SYSTEM_MODE);
        run.ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS;
        Database.update(run, true, AccessLevel.SYSTEM_MODE);

        if (plan.rows.isEmpty()) {
            // Nothing to send to IDP: completion moves the run straight on
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ run.Id });
            return;
        }
        // Scope 1 by default: IDP takes one file per request and each file's VersionData can be up to 15 MB of heap
        Decimal batchSize = DNAMS_PackageReviewPipelineService.settings().ExtractionBatchSize__c;
        Database.executeBatch(new DNAMSExtractionSubmitBatch(run.Id), Math.max(1, batchSize == null ? 1 : batchSize.intValue()));
    }

    /**
     * @description Steps [2], [3], [5]: one Pending stage row per mapped file; unmapped files mark their element Not Applicable.
     * @param runId       Run id
     * @param elementById Passed elements of the run's package
     * @return            Rows to insert plus the element ids per outcome
     **/
    private static StagePlan buildPlan(Id runId, Map<Id, DNAMS_Package_Element__c> elementById) {
        StagePlan plan = new StagePlan(runId);
        if (elementById.isEmpty()) {
            return plan;
        }
        List<ContentDocumentLink> links = [
            SELECT LinkedEntityId, ContentDocumentId, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :elementById.keySet()
            WITH SYSTEM_MODE
        ];
        Set<Id> versionIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            versionIds.add(link.ContentDocument.LatestPublishedVersionId);
        }
        Map<Id, ContentVersion> versionById = new Map<Id, ContentVersion>(
            [SELECT Id, ContentDocumentId, Title, FileExtension, DocumentClassifiedAs__c FROM ContentVersion WHERE Id IN :versionIds WITH SYSTEM_MODE]
        );
        Map<String, DNAMSIDPWrapper.ActionConfig> actionByType = DNAMSIDPActionUtil.getActionsByDocumentType();

        for (ContentDocumentLink link : links) {
            ContentVersion version = versionById.get(link.ContentDocument.LatestPublishedVersionId);
            if (version == null || String.isBlank(version.DocumentClassifiedAs__c)) {
                continue; // only files stamped by classification are extracted
            }
            DNAMSIDPWrapper.ActionConfig action = actionByType.get(version.DocumentClassifiedAs__c.toLowerCase());
            if (action == null) {
                plan.notApplicableIds.add(link.LinkedEntityId);
                continue;
            }
            plan.addRow(elementById.get(link.LinkedEntityId), version, action);
        }
        return plan;
    }

    /**
     * @description Hands the remaining runs back to the event channel, one Start Extraction event per run.
     * @param remainingIds Run ids not processed in this transaction
     **/
    private static void republish(List<Id> remainingIds) {
        if (remainingIds.isEmpty()) {
            return;
        }
        List<DNAMSIDPEvent__e> events = new List<DNAMSIDPEvent__e>();
        for (Id runId : remainingIds) {
            events.add(new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_START_EXTRACTION, ReviewRunId__c = runId));
        }
        EventBus.publish(events);
    }

    /**
     * @description Fails the job's runs when the queueable ends with an exception its own catch could not handle
     *              (for example a LimitException), so the run does not stay Running forever. Shared by the
     *              extraction queueables.
     **/
    public class RunFailureFinalizer implements Finalizer {
        private Set<Id> runIds;
        private String sourceClass;

        /**
         * @description Creates the finalizer.
         * @param runIds      Runs of the job
         * @param sourceClass Queueable class name for the log
         **/
        public RunFailureFinalizer(Set<Id> runIds, String sourceClass) {
            this.runIds = runIds;
            this.sourceClass = sourceClass;
        }

        /**
         * @description Logs and fails each run after an unhandled exception; does nothing after success.
         * @param context Finalizer context
         **/
        public void execute(FinalizerContext context) {
            if (context.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
                return;
            }
            // shortcut: one log + failRun per run; extraction jobs carry a single run, so this runs once
            for (Id runId : runIds) {
                DNAMSErrorLogHelper.logException(context.getException(), runId, sourceClass);
            }
        }
    }

    /**
     * @description Stage rows to create and the element outcomes of one run.
     **/
    private class StagePlan {
        private Id runId;
        private List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        private Set<Id> mappedIds = new Set<Id>();
        private Set<Id> notApplicableIds = new Set<Id>();

        /**
         * @description Creates an empty plan for one run.
         * @param runId Run id
         **/
        private StagePlan(Id runId) {
            this.runId = runId;
        }

        /**
         * @description Adds a Pending Extraction stage row for one mapped file.
         * @param element Package element the file belongs to
         * @param version Latest published version of the file
         * @param action  IDP action for the file's document type
         **/
        private void addRow(DNAMS_Package_Element__c element, ContentVersion version, DNAMSIDPWrapper.ActionConfig action) {
            String extension = String.isBlank(version.FileExtension) ? '' : '.' + version.FileExtension;
            mappedIds.add(element.Id);
            rows.add(
                new AIReviewStageResult__c(
                    ReviewRun__c = runId,
                    PackageElement__c = element.Id,
                    Stage__c = DNAMSPipelineConstants.STAGE_EXTRACTION,
                    ProcessingStatus__c = DNAMSPipelineConstants.ROW_PENDING,
                    CallbackToken__c = DNAMSCallbackSignatureUtil.generateToken(),
                    IDPActionName__c = action.developerName,
                    IDPActionId__c = action.actionId,
                    IDPActionVersion__c = action.actionVersion,
                    ElementType__c = element.Element_Type__r?.Name,
                    DocumentType__c = version.DocumentClassifiedAs__c,
                    DocumentTitle__c = (version.Title + extension).left(TITLE_LENGTH),
                    ContentDocumentId__c = version.ContentDocumentId,
                    ContentVersionId__c = version.Id
                )
            );
        }

        /**
         * @description Element updates: mapped elements go In Progress; elements with only unmapped files go Not Applicable.
         * @return      Element records to update
         **/
        private List<DNAMS_Package_Element__c> elementUpdates() {
            List<DNAMS_Package_Element__c> updates = new List<DNAMS_Package_Element__c>();
            for (Id elementId : mappedIds) {
                updates.add(
                    new DNAMS_Package_Element__c(
                        Id = elementId,
                        Extraction_Status__c = DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS,
                        Current_Stage__c = DNAMSPipelineConstants.STAGE_EXTRACTION
                    )
                );
            }
            for (Id elementId : notApplicableIds) {
                if (!mappedIds.contains(elementId)) {
                    updates.add(new DNAMS_Package_Element__c(Id = elementId, Extraction_Status__c = DNAMSPipelineConstants.ELEMENT_NOT_APPLICABLE));
                }
            }
            return updates;
        }
    }
}
