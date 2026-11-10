/**
 * @description     LLD page 5 steps [2]-[7]: starts extraction for a run that passed classification. Reads the files of
 *                  the Passed elements, maps each file's DocumentClassifiedAs__c to a DNAMSIDPAction__mdt, creates one
 *                  Pending AIReviewStageResult__c per mapped file and starts DNAMSExtractionSubmitBatch. Files without a
 *                  mapping set their element's Extraction_Status__c to Not Applicable.
 *                  One run is processed per transaction; further run ids are re-published as Start Extraction events
 *                  so each run gets its own limits and its completion can enqueue its own follow-up job.
 *                  Changes Only runs: a file whose baseline extraction is still valid (same file version, document
 *                  type and IDP action/version, finished OK) gets a Completed copy of the baseline row instead of a
 *                  Pending one, so it is never sent to IDP; when every row is reused, completion runs at once.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Changes Only runs reuse still-valid baseline extractions
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 * 1.1   2026-11-10   Abhishek Dutta  Changes Only runs reuse still-valid baseline extractions
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
                SELECT Id, Name, Element_Type__r.Name
                FROM DNAMS_Package_Element__c
                WHERE Package__c = :run.Package__c AND Classification_Status__c = :DNAMS_PackageReviewPipelineService.STAGE_PASSED
                WITH SYSTEM_MODE
            ]
        );
        // null = All run: every mapped file is sent to IDP (no baseline comparison)
        Id baselineRunId = DNAMSRunChangeDetector.baselineRunIdFor(run.Id);
        StagePlan plan = buildPlan(run.Id, elementById, baselineRunId == null ? null : new ExtractionBaseline(baselineRunId));
        Database.insert(plan.rows, true, AccessLevel.SYSTEM_MODE);
        Database.update(plan.elementUpdates(), true, AccessLevel.SYSTEM_MODE);
        run.ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS;
        Database.update(run, true, AccessLevel.SYSTEM_MODE);
        if (baselineRunId != null) {
            DNAMSRunChangeDetector.appendChangeSummary(
                run.Id,
                DNAMSRunChangeDetector.SUMMARY_EXTRACTION,
                DNAMSRunChangeDetector.stageLine(plan.reusedCount, plan.pendingCount, plan.rerunReasons)
            );
        }

        if (plan.pendingCount == 0) {
            // Nothing to send to IDP (no mapped file, or every extraction reused): completion moves the run straight on
            DNAMSExtractionCompletionHelper.completeExtraction(new Set<Id>{ run.Id });
            return;
        }
        // Scope 1 by default: IDP takes one file per request and each file's VersionData can be up to 15 MB of heap
        Decimal batchSize = DNAMS_PackageReviewPipelineService.settings().ExtractionBatchSize__c;
        Database.executeBatch(new DNAMSExtractionSubmitBatch(run.Id), Math.max(1, batchSize == null ? 1 : batchSize.intValue()));
    }

    /**
     * @description Steps [2], [3], [5]: one Pending stage row per mapped file (or, on a Changes Only run, a reused
     *              copy of a still-valid baseline row); unmapped files mark their element Not Applicable.
     * @param runId       Run id
     * @param elementById Passed elements of the run's package
     * @param baseline    Baseline extractions of a Changes Only run, or null for an All run
     * @return            Rows to insert plus the element ids per outcome
     **/
    private static StagePlan buildPlan(Id runId, Map<Id, DNAMS_Package_Element__c> elementById, ExtractionBaseline baseline) {
        StagePlan plan = new StagePlan(runId, baseline);
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
     * @description Baseline Extraction rows of a Changes Only run and the reuse decision per file.
     **/
    private class ExtractionBaseline {
        private Map<String, AIReviewStageResult__c> rowByFileKey = new Map<String, AIReviewStageResult__c>();
        private Set<String> documentKeys = new Set<String>();

        /**
         * @description Loads every Extraction row of the baseline run (finished or not, so the reason can say why).
         * @param baselineRunId Baseline run id
         **/
        private ExtractionBaseline(Id baselineRunId) {
            for (AIReviewStageResult__c row : DNAMSRunChangeDetector.stageRows(baselineRunId, DNAMSPipelineConstants.STAGE_EXTRACTION)) {
                // Rows come oldest first; a finished row is never replaced by an unfinished one of the same file
                String fileKey = DNAMSRunChangeDetector.fileKey(row);
                if (!DNAMSRunChangeDetector.isFinishedExtraction(rowByFileKey.get(fileKey))) {
                    rowByFileKey.put(fileKey, row);
                }
                documentKeys.add(documentKey(row.PackageElement__c, row.ContentDocumentId__c));
            }
        }

        /**
         * @description Why the file must be extracted again; null when the baseline row can be reused.
         * @param element Package element the file belongs to
         * @param version Latest published version of the file
         * @param action  Current IDP action for the file's document type
         * @return        Short reason (e.g. "new version", "IDP action version 1.0.0 -> 1.1.0"), or null
         **/
        private String changeReason(DNAMS_Package_Element__c element, ContentVersion version, DNAMSIDPWrapper.ActionConfig action) {
            AIReviewStageResult__c baselineRow = baselineRow(element, version);
            if (baselineRow == null && documentKeys.contains(documentKey(element.Id, version.ContentDocumentId))) {
                return 'new version';
            }
            return DNAMSRunChangeDetector.extractionChangeReason(baselineRow, version.DocumentClassifiedAs__c, action);
        }

        /**
         * @description The baseline row of exactly this file version on this element.
         * @param element Package element the file belongs to
         * @param version Latest published version of the file
         * @return        Baseline row, or null
         **/
        private AIReviewStageResult__c baselineRow(DNAMS_Package_Element__c element, ContentVersion version) {
            return rowByFileKey.get(DNAMSRunChangeDetector.fileKey(element.Id, version.ContentDocumentId, version.Id));
        }

        /**
         * @description Element + document key (any version), used to tell a new version from a new file.
         * @param elementId         Package element id
         * @param contentDocumentId ContentDocument id (Id or text)
         * @return                  "elementId|contentDocumentId" with 15-character ids
         **/
        private String documentKey(Id elementId, String contentDocumentId) {
            return String.valueOf(elementId).left(15) + DNAMSRunChangeDetector.KEY_SEPARATOR + (contentDocumentId ?? '').left(15);
        }
    }

    /**
     * @description Stage rows to create and the element outcomes of one run.
     **/
    private class StagePlan {
        private Id runId;
        private ExtractionBaseline baseline;
        private List<AIReviewStageResult__c> rows = new List<AIReviewStageResult__c>();
        private Set<Id> mappedIds = new Set<Id>();
        private Set<Id> notApplicableIds = new Set<Id>();
        private Integer pendingCount = 0;
        private Integer reusedCount = 0;
        private List<String> rerunReasons = new List<String>();

        /**
         * @description Creates an empty plan for one run.
         * @param runId    Run id
         * @param baseline Baseline extractions of a Changes Only run, or null for an All run
         **/
        private StagePlan(Id runId, ExtractionBaseline baseline) {
            this.runId = runId;
            this.baseline = baseline;
        }

        /**
         * @description Adds the Extraction stage row for one mapped file: a reused copy of the baseline row when it
         *              is still valid, otherwise a Pending row for IDP (with its re-run reason on a Changes Only run).
         * @param element Package element the file belongs to
         * @param version Latest published version of the file
         * @param action  IDP action for the file's document type
         **/
        private void addRow(DNAMS_Package_Element__c element, ContentVersion version, DNAMSIDPWrapper.ActionConfig action) {
            String extension = String.isBlank(version.FileExtension) ? '' : '.' + version.FileExtension;
            mappedIds.add(element.Id);
            if (baseline != null) {
                String reason = baseline.changeReason(element, version, action);
                if (reason == null) {
                    rows.add(DNAMSRunChangeDetector.cloneForReuse(baseline.baselineRow(element, version), runId));
                    reusedCount++;
                    return;
                }
                rerunReasons.add(element.Name + ' / ' + version.Title + extension + ': ' + reason);
            }
            pendingCount++;
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
