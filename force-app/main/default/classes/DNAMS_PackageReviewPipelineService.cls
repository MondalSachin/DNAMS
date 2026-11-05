/**
 * @description     Deterministic skeleton of the AI package review pipeline (G1.13, Tier 2 per G1.14). Diagram steps:
 *                   1b  RMR re-run / cancel                       -> requestRerun / cancelActiveRun
 *                   3   anything already running?                 -> handleReviewRequests
 *                   5a/5b duplicate: Discarded run + RMR          -> handleReviewRequests / notifyOwners
 *                   6/7 create Running run, enqueue               -> handleReviewRequests
 *                   15-17, 22, 23 element results and completion  -> completeClassification (pass: run stays Running and
 *                                                                  extraction starts through DNAMSIDPEvent__e)
 *                   18-20 narrative, owner check, RMR email       -> DNAMS_PackageNarrativeQueueable
 *                  Results are kept per element (stage statuses + a short rule-based narrative); there is no
 *                  document-level record. Every step re-checks the run Status; only Running runs continue.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details PMD clean-up: ApexDoc, system-mode SOQL/DML, complexity split into helpers
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  PMD clean-up: ApexDoc, system-mode SOQL/DML, complexity split into helpers
 **/
// Exception to guideline: without sharing because the pipeline is invoked from the platform event subscriber, async jobs and RMR actions
// Class name kept: renaming would break the many callers, tests and metadata that reference it
@SuppressWarnings('PMD.ClassNamingConventions')
public without sharing class DNAMS_PackageReviewPipelineService {
    public static final String SOURCE_DEALER_SUBMIT = 'Dealer Submit';
    public static final String SOURCE_DEALER_RESUBMIT = 'Dealer Resubmit';
    public static final String SOURCE_RMR_RERUN = 'RMR Rerun';
    public static final String RUN_RUNNING = 'Running';
    public static final String RUN_CANCELLING = 'Cancelling';
    public static final String RUN_CANCELLED = 'Cancelled';
    public static final String RUN_DISCARDED = 'Discarded';
    public static final String RUN_COMPLETED = 'Completed';
    public static final String RUN_FAILED = 'Failed';
    public static final Set<String> ACTIVE_RUN_STATUSES = new Set<String>{ RUN_RUNNING, RUN_CANCELLING };
    public static final String RESULT_PASSED = 'Passed';
    public static final String RESULT_NEEDS_REVIEW = 'Needs Review';
    public static final String PACKAGE_RMR_PENDING = 'RMR Pending';
    public static final String PACKAGE_UNDER_REVIEW = 'Under Review';
    public static final String DUPLICATE_REASON = 'Duplicate request - a review run is already in progress for this package.';
    public static final String RMR_PERMISSION = 'DNAMS_RMR';

    // Element stage statuses (same set for every stage).
    public static final String STAGE_IN_PROGRESS = 'In Progress';
    public static final String STAGE_PASSED = 'Passed';
    public static final String STAGE_NEEDS_REVIEW = 'Needs Review';
    public static final String STAGE_FAILED = 'Failed';
    public static final String STAGE_CLASSIFICATION = 'Classification';

    @TestVisible
    private static DNAMS_Pipeline_Setting__mdt settingsOverride;

    // Start Extraction events published in this transaction, so tests can assert on them.
    @TestVisible
    private static List<DNAMSIDPEvent__e> publishedEvents = new List<DNAMSIDPEvent__e>();

    /**
     * @description Returns the pipeline settings (test override first, else the Default record).
     * @return      The DNAMS_Pipeline_Setting__mdt in effect
     * @throws PipelineException when the Default record is missing
     **/
    public static DNAMS_Pipeline_Setting__mdt settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_Pipeline_Setting__mdt.getInstance('Default');
        if (setting == null) {
            throw new PipelineException('DNAMS_Pipeline_Setting__mdt record "Default" is missing.');
        }
        return setting;
    }

    // ------------------------------------------------------------------ Steps 3, 5a, 5b, 6, 7

    /**
     * @description Creates a Running run per request (Discarded when the package already has an active run),
     *              enqueues classification for the Running ones and notifies owners of discarded requests.
     * @param requests Review request events from the subscriber
     **/
    public static void handleReviewRequests(List<DNAMS_Package_Review_Requested__e> requests) {
        Set<Id> packageIds = new Set<Id>();
        for (DNAMS_Package_Review_Requested__e request : requests) {
            packageIds.add(request.Package_Id__c);
        }
        Set<Id> busyPackages = activePackageIds(packageIds);

        List<AI_Package_Review_Run__c> runs = new List<AI_Package_Review_Run__c>();
        for (DNAMS_Package_Review_Requested__e request : requests) {
            Boolean duplicate = busyPackages.contains(request.Package_Id__c);
            busyPackages.add(request.Package_Id__c); // a second request in the same batch is also a duplicate
            runs.add(newRun(request, duplicate));
        }
        insert as system runs;

        Map<Id, AI_Package_Review_Run__c> discardedByPackage = startRuns(runs);
        update as system runs;
        if (!discardedByPackage.isEmpty()) {
            notifyOwners(
                discardedByPackage,
                'review request discarded (already running)',
                'Status changed to Dealer Submitted, but a review run is already running, so this run was cancelled.\n\n' +
                'To re-process: stop the running pipeline, then re-run.'
            );
        }
    }

    /**
     * @description Packages that already have a Running or Cancelling run.
     * @param packageIds Packages of the incoming requests
     * @return           Subset of packageIds with an active run
     **/
    private static Set<Id> activePackageIds(Set<Id> packageIds) {
        Set<Id> busyPackages = new Set<Id>();
        for (AI_Package_Review_Run__c run : [
            SELECT Package__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c IN :packageIds AND Status__c IN :ACTIVE_RUN_STATUSES
            WITH SYSTEM_MODE
        ]) {
            busyPackages.add(run.Package__c);
        }
        return busyPackages;
    }

    /**
     * @description Builds the run for one request: Discarded with the duplicate reason, or Running with the prompt template.
     * @param request   Review request event
     * @param duplicate True when the package already has an active run
     * @return          Unsaved AI_Package_Review_Run__c
     **/
    private static AI_Package_Review_Run__c newRun(DNAMS_Package_Review_Requested__e request, Boolean duplicate) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = request.Package_Id__c,
            Status__c = RUN_RUNNING,
            Reason__c = null,
            Trigger_Source__c = request.Trigger_Source__c,
            Requested_By__c = request.Requested_By_Id__c,
            Started_At__c = System.now(),
            Ended_At__c = null,
            Prompt_Template__c = null
        );
        if (duplicate) {
            run.Status__c = RUN_DISCARDED;
            run.Reason__c = DUPLICATE_REASON;
            run.Ended_At__c = System.now();
        } else {
            run.Prompt_Template__c = settings().Prompt_Template__c;
        }
        return run;
    }

    /**
     * @description Enqueues classification for each Running run (stamping Job_Id__c) and collects the discarded ones.
     * @param runs Inserted runs
     * @return     Discarded runs keyed by package Id
     **/
    // One classification job per new Running run is the pipeline contract; requests arrive in small event batches
    @SuppressWarnings('PMD.OperationWithLimitsInLoop')
    private static Map<Id, AI_Package_Review_Run__c> startRuns(List<AI_Package_Review_Run__c> runs) {
        Map<Id, AI_Package_Review_Run__c> discardedByPackage = new Map<Id, AI_Package_Review_Run__c>();
        for (AI_Package_Review_Run__c run : runs) {
            if (run.Status__c == RUN_DISCARDED) {
                discardedByPackage.put(run.Package__c, run);
            } else {
                run.Job_Id__c = System.enqueueJob(new DNAMS_ClassificationStarterQueueable(run.Id));
            }
        }
        return discardedByPackage;
    }

    // ------------------------------------------------------------------ Step 1b: RMR re-run and cancel

    /**
     * @description Publishes a review request, so the re-run goes through the same duplicate check (step 3).
     * @param packageId Package to re-run
     **/
    public static void requestRerun(Id packageId) {
        EventBus.publish(
            new DNAMS_Package_Review_Requested__e(
                Package_Id__c = packageId,
                Trigger_Source__c = SOURCE_RMR_RERUN,
                Requested_By_Id__c = UserInfo.getUserId()
            )
        );
    }

    /**
     * @description A running review is marked Cancelling and stops at its next step.
     * @param packageId Package whose Running run is cancelled
     **/
    public static void cancelActiveRun(Id packageId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c = :RUN_RUNNING
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        for (AI_Package_Review_Run__c run : runs) {
            run.Status__c = RUN_CANCELLING;
            run.Reason__c = 'Cancelled by ' + UserInfo.getName() + '.';
        }
        update as system runs;
    }

    // ------------------------------------------------------------------ Steps 15, 16, 17, 22, 23

    /**
     * @description Finalises each element's Classification stage (step 15 -> 16). With issues the run completes as
     *              Needs Review; on a pass it stays Running with Extraction Pending and extraction is started by a
     *              DNAMSIDPEvent__e. The batch has already set Passed / Needs Review / Failed on elements that had files;
     *              here, required elements without files fail as missing and any element left In Progress fails as
     *              not completed.
     * @param runId Review run to complete
     **/
    public static void completeClassification(Id runId) {
        AI_Package_Review_Run__c run = lockRun(runId);
        if (run == null) {
            return;
        }
        List<String> summary = new List<String>();
        List<DNAMS_Package_Element__c> updates = new List<DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Is_Required__c, Classification_Status__c, Element_Narrative__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :run.Package__c
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            ElementOutcome outcome = new ElementOutcome(element);
            if (outcome.isIssue()) {
                summary.add('- ' + element.Name + ' [' + outcome.status + ']: ' + outcome.narrative);
            }
            if (outcome.isChanged(element)) {
                updates.add(outcome.toUpdate(element.Id));
            }
        }
        Boolean anyIssue = !summary.isEmpty();
        DNAMS_Package__c pkg = new DNAMS_Package__c(Id = run.Package__c, Health__c = 'Green', Status__c = PACKAGE_UNDER_REVIEW, AI_Narrative__c = null, AI_Narrative_JSON__c = null);
        run.Classification_Processing_Status__c = 'Completed';
        if (anyIssue) {
            pkg.Health__c = 'Red';
            pkg.Status__c = PACKAGE_RMR_PENDING;
            run.Status__c = RUN_COMPLETED;
            run.Overall_Result__c = RESULT_NEEDS_REVIEW;
            run.Issue_Summary__c = String.join(summary, '\n').left(32768);
            run.Ended_At__c = System.now();
        } else {
            // Steps 22 -> 23: the run stays Running so lockRun, cancel and the duplicate check keep working during extraction.
            run.ExtractionProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_PENDING;
            run.Issue_Summary__c = null;
        }
        update as system updates;
        update as system pkg;
        update as system run;

        // Both start only after this transaction commits.
        if (anyIssue) {
            System.enqueueJob(new DNAMS_PackageNarrativeQueueable(runId)); // steps 17 -> 18-20
        } else {
            publishStartExtraction(runId);
        }
    }

    /**
     * @description Publishes the Start Extraction event (PublishAfterCommit); its subscriber runs as the IDP
     *              integration user and starts DNAMSExtractionStarterQueueable.
     * @param runId Review run whose extraction should start
     * @throws PipelineException when the event cannot be published
     **/
    private static void publishStartExtraction(Id runId) {
        DNAMSIDPEvent__e event = new DNAMSIDPEvent__e(EventType__c = DNAMSPipelineConstants.EVENT_START_EXTRACTION, ReviewRunId__c = runId);
        Database.SaveResult result = EventBus.publish(event);
        if (!result.isSuccess()) {
            throw new PipelineException('Start Extraction event not published: ' + result.getErrors()[0].getMessage());
        }
        publishedEvents.add(event);
    }

    // ------------------------------------------------------------------ Step 19: owner check + notification

    /**
     * @description Owner is a user with the DNAMS RMR permission -> email; queue-owned or anyone else -> recorded on the run only.
     * @param runsByPackage Runs to notify about, keyed by package Id
     * @param subjectSuffix Email subject suffix, also used in the run note
     * @param body          Email body text
     **/
    public static void notifyOwners(Map<Id, AI_Package_Review_Run__c> runsByPackage, String subjectSuffix, String body) {
        new OwnerNotifier().send(runsByPackage, subjectSuffix, body);
    }

    // ------------------------------------------------------------------ Run status helpers

    /**
     * @description Returns the run (locked) when it is still Running; otherwise settles a cancellation and returns null.
     *              A deleted run also returns null, so queued work for it stops quietly.
     * @param runId Review run to lock
     * @return      The locked Running run, or null
     **/
    public static AI_Package_Review_Run__c lockRun(Id runId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, Package__c, Status__c, Classification_Processing_Status__c, ExtractionProcessingStatus__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (runs.isEmpty()) {
            return null;
        }
        AI_Package_Review_Run__c run = runs[0];
        if (run.Status__c == RUN_RUNNING) {
            return run;
        }
        if (run.Status__c == RUN_CANCELLING) {
            run.Status__c = RUN_CANCELLED;
            run.Ended_At__c = System.now();
            update as system run;
        }
        return null;
    }

    /**
     * @description Whether the run exists and is still Running.
     * @param runId Review run to check
     * @return      True when the run Status is Running
     **/
    public static Boolean isRunning(Id runId) {
        List<AI_Package_Review_Run__c> runs = [SELECT Status__c FROM AI_Package_Review_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
        return !runs.isEmpty() && runs[0].Status__c == RUN_RUNNING;
    }

    /**
     * @description Marks the run Failed against the Classification stage.
     * @param runId Review run to fail
     * @param ex    Exception that stopped the stage
     **/
    public static void failRun(Id runId, Exception ex) {
        failRun(runId, AI_Package_Review_Run__c.Classification_Processing_Status__c, ex);
    }

    /**
     * @description Marks the run Failed and records the error against the stage that crashed.
     * @param runId            Review run to fail
     * @param stageStatusField Stage status field set to Failed, e.g. AI_Package_Review_Run__c.ExtractionProcessingStatus__c
     * @param ex               Exception that stopped the stage
     **/
    public static void failRun(Id runId, Schema.SObjectField stageStatusField, Exception ex) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Id = runId,
            Status__c = RUN_FAILED,
            Ended_At__c = System.now(),
            Error__c = (ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString()).left(32768)
        );
        run.put(stageStatusField, DNAMSPipelineConstants.RUN_STAGE_FAILED);
        update as system run;
    }

    /**
     * @description Final Classification status and narrative of one element at completion (step 15 -> 16).
     **/
    private class ElementOutcome {
        public String status;
        public String narrative;

        /**
         * @description Required elements without a status fail as missing; elements left In Progress fail as not completed.
         * @param element Package element with Name, Is_Required__c, Classification_Status__c, Element_Narrative__c
         **/
        public ElementOutcome(DNAMS_Package_Element__c element) {
            status = element.Classification_Status__c;
            narrative = element.Element_Narrative__c;
            if (status == null && element.Is_Required__c) {
                status = STAGE_FAILED;
                narrative = 'Required document missing. Upload the ' + element.Name + ' document.';
            } else if (status == STAGE_IN_PROGRESS) {
                status = STAGE_FAILED;
                narrative = 'The AI check did not finish. Re-run the review.';
            }
        }

        /**
         * @description Whether the element goes into the run's issue summary.
         * @return      True when Failed or Needs Review
         **/
        public Boolean isIssue() {
            return status == STAGE_FAILED || status == STAGE_NEEDS_REVIEW;
        }

        /**
         * @description Whether the outcome differs from what is stored on the element.
         * @param element The queried element
         * @return        True when status or narrative changed
         **/
        public Boolean isChanged(DNAMS_Package_Element__c element) {
            return status != element.Classification_Status__c || narrative != element.Element_Narrative__c;
        }

        /**
         * @description Element update carrying the outcome on the Classification stage.
         * @param elementId Element to update
         * @return          Unsaved DNAMS_Package_Element__c
         **/
        public DNAMS_Package_Element__c toUpdate(Id elementId) {
            return new DNAMS_Package_Element__c(
                Id = elementId,
                Classification_Status__c = status,
                Current_Stage__c = STAGE_CLASSIFICATION,
                Element_Narrative__c = narrative?.left(255)
            );
        }
    }

    /**
     * @description Step 19 owner check and RMR email, recording the outcome on each run's Reason__c.
     **/
    private without sharing class OwnerNotifier {
        /**
         * @description Emails RMR owners and appends a note to every run.
         * @param runsByPackage Runs to notify about, keyed by package Id
         * @param subjectSuffix Email subject suffix, also used in the run note
         * @param body          Email body text
         **/
        public void send(Map<Id, AI_Package_Review_Run__c> runsByPackage, String subjectSuffix, String body) {
            Map<Id, DNAMS_Package__c> packages = new Map<Id, DNAMS_Package__c>(
                [SELECT Id, Name, Package_Name__c, OwnerId, Buying_Dealer__r.Name FROM DNAMS_Package__c WHERE Id IN :runsByPackage.keySet() WITH SYSTEM_MODE]
            );
            Set<Id> ownerIds = new Set<Id>();
            for (DNAMS_Package__c pkg : packages.values()) {
                ownerIds.add(pkg.OwnerId);
            }
            Set<Id> rmrUsers = rmrUserIds(ownerIds);

            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            List<AI_Package_Review_Run__c> notes = new List<AI_Package_Review_Run__c>();
            for (DNAMS_Package__c pkg : packages.values()) {
                AI_Package_Review_Run__c run = runsByPackage.get(pkg.Id);
                String note = 'Notification "' + subjectSuffix + '": ';
                if (!rmrUsers.contains(pkg.OwnerId)) {
                    notes.add(appendReason(run, note + 'RMR not emailed - the package is owned by a queue or a non-RMR user.'));
                    continue;
                }
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setTargetObjectId(pkg.OwnerId);
                email.setSaveAsActivity(false);
                email.setSubject('DNAMS ' + pkg.Name + ': ' + subjectSuffix);
                email.setPlainTextBody(
                    (pkg.Buying_Dealer__r == null ? '' : pkg.Buying_Dealer__r.Name + ' - ') + pkg.Name + ' (' + pkg.Package_Name__c + ')\n\n' +
                    body + '\n\nOpen the package: ' + URL.getOrgDomainUrl().toExternalForm() + '/' + pkg.Id
                );
                emails.add(email);
                notes.add(appendReason(run, note + 'emailed the package owner.'));
            }
            if (!emails.isEmpty()) {
                Messaging.sendEmail(emails, false);
            }
            update as system notes;
        }

        /**
         * @description Active users among the candidates that hold the DNAMS RMR permission set.
         * @param candidateIds Package owner Ids (users or queues)
         * @return             User Ids with the RMR permission
         **/
        private Set<Id> rmrUserIds(Set<Id> candidateIds) {
            Set<Id> userIds = new Set<Id>();
            for (Id candidate : candidateIds) {
                if (candidate?.getSobjectType() == User.SObjectType) {
                    userIds.add(candidate);
                }
            }
            Set<Id> rmr = new Set<Id>();
            if (userIds.isEmpty()) {
                return rmr;
            }
            for (PermissionSetAssignment assignment : [
                SELECT AssigneeId
                FROM PermissionSetAssignment
                WHERE AssigneeId IN :userIds AND PermissionSet.Name = :RMR_PERMISSION AND Assignee.IsActive = TRUE
                WITH SYSTEM_MODE
            ]) {
                rmr.add(assignment.AssigneeId);
            }
            return rmr;
        }

        /**
         * @description Run update with the text appended to its current Reason__c (max 4000 chars).
         * @param run  Run to annotate
         * @param text Line to append
         * @return     Unsaved AI_Package_Review_Run__c with the new Reason__c
         **/
        private AI_Package_Review_Run__c appendReason(AI_Package_Review_Run__c run, String text) {
            String existing = [SELECT Reason__c FROM AI_Package_Review_Run__c WHERE Id = :run.Id WITH SYSTEM_MODE].Reason__c;
            return new AI_Package_Review_Run__c(Id = run.Id, Reason__c = ((String.isBlank(existing) ? '' : existing + '\n') + text).left(4000));
        }
    }

    /**
     * @description Pipeline failure raised for missing configuration or unexpected model output.
     **/
    public class PipelineException extends Exception {
    }
}
