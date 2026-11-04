/**
 * Deterministic skeleton of the AI package review pipeline (G1.13, Tier 2 per G1.14). Diagram steps:
 *  1b  RMR re-run / cancel                       -> requestRerun / cancelActiveRun
 *  3   anything already running?                 -> handleReviewRequests
 *  5a/5b duplicate: Discarded run + RMR          -> handleReviewRequests / notifyOwners
 *  6/7 create Running run, enqueue               -> handleReviewRequests
 *  15-17, 22, 23 element results and completion  -> completeClassification
 *  18-20 narrative, owner check, RMR email       -> DNAMS_PackageNarrativeQueueable
 * Results are kept per element (stage statuses + a short rule-based narrative); there is no document-level record.
 * Every step re-checks the run Status; only Running runs continue.
 * Runs without sharing: invoked from the platform event subscriber, async jobs and RMR actions.
 */
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

    public static void handleReviewRequests(List<DNAMS_Package_Review_Requested__e> requests) {
        Set<Id> packageIds = new Set<Id>();
        for (DNAMS_Package_Review_Requested__e request : requests) {
            packageIds.add(request.Package_Id__c);
        }
        Set<Id> busyPackages = new Set<Id>();
        for (AI_Package_Review_Run__c run : [
            SELECT Package__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c IN :packageIds AND Status__c IN :ACTIVE_RUN_STATUSES
        ]) {
            busyPackages.add(run.Package__c);
        }

        List<AI_Package_Review_Run__c> runs = new List<AI_Package_Review_Run__c>();
        for (DNAMS_Package_Review_Requested__e request : requests) {
            Boolean duplicate = busyPackages.contains(request.Package_Id__c);
            busyPackages.add(request.Package_Id__c); // a second request in the same batch is also a duplicate
            runs.add(
                new AI_Package_Review_Run__c(
                    Package__c = request.Package_Id__c,
                    Status__c = duplicate ? RUN_DISCARDED : RUN_RUNNING,
                    Reason__c = duplicate ? DUPLICATE_REASON : null,
                    Trigger_Source__c = request.Trigger_Source__c,
                    Requested_By__c = request.Requested_By_Id__c,
                    Started_At__c = System.now(),
                    Ended_At__c = duplicate ? System.now() : null,
                    Prompt_Template__c = duplicate ? null : settings().Prompt_Template__c
                )
            );
        }
        insert runs;

        Map<Id, AI_Package_Review_Run__c> discardedByPackage = new Map<Id, AI_Package_Review_Run__c>();
        for (AI_Package_Review_Run__c run : runs) {
            if (run.Status__c == RUN_DISCARDED) {
                discardedByPackage.put(run.Package__c, run);
            } else {
                run.Job_Id__c = System.enqueueJob(new DNAMS_ClassificationStarterQueueable(run.Id));
            }
        }
        update runs;
        if (!discardedByPackage.isEmpty()) {
            notifyOwners(
                discardedByPackage,
                'review request discarded (already running)',
                'Status changed to Dealer Submitted, but a review run is already running, so this run was cancelled.\n\n' +
                'To re-process: stop the running pipeline, then re-run.'
            );
        }
    }

    // ------------------------------------------------------------------ Step 1b: RMR re-run and cancel

    /** Publishes a review request, so the re-run goes through the same duplicate check (step 3). */
    public static void requestRerun(Id packageId) {
        EventBus.publish(
            new DNAMS_Package_Review_Requested__e(
                Package_Id__c = packageId,
                Trigger_Source__c = SOURCE_RMR_RERUN,
                Requested_By_Id__c = UserInfo.getUserId()
            )
        );
    }

    /** A running review is marked Cancelling and stops at its next step. */
    public static void cancelActiveRun(Id packageId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c = :RUN_RUNNING
            FOR UPDATE
        ];
        for (AI_Package_Review_Run__c run : runs) {
            run.Status__c = RUN_CANCELLING;
            run.Reason__c = 'Cancelled by ' + UserInfo.getName() + '.';
        }
        update runs;
    }

    // ------------------------------------------------------------------ Steps 15, 16, 17, 22, 23

    /**
     * Finalises each element's Classification stage and completes the run (step 15 -> 16).
     * The batch has already set Passed / Needs Review / Failed on elements that had files; here, required elements
     * without files fail as missing and any element left In Progress fails as not completed.
     */
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
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            String status = element.Classification_Status__c;
            String narrative = element.Element_Narrative__c;
            if (status == null && element.Is_Required__c) {
                status = STAGE_FAILED;
                narrative = 'Required document missing. Upload the ' + element.Name + ' document.';
            } else if (status == STAGE_IN_PROGRESS) {
                status = STAGE_FAILED;
                narrative = 'The AI check did not finish. Re-run the review.';
            }
            if (status == STAGE_FAILED || status == STAGE_NEEDS_REVIEW) {
                summary.add('- ' + element.Name + ' [' + status + ']: ' + narrative);
            }
            if (status != element.Classification_Status__c || narrative != element.Element_Narrative__c) {
                updates.add(
                    new DNAMS_Package_Element__c(
                        Id = element.Id,
                        Classification_Status__c = status,
                        Current_Stage__c = STAGE_CLASSIFICATION,
                        Element_Narrative__c = narrative?.left(255)
                    )
                );
            }
        }
        Boolean anyIssue = !summary.isEmpty();
        update updates;
        update new DNAMS_Package__c(
            Id = run.Package__c,
            Health__c = anyIssue ? 'Red' : 'Green',
            Status__c = anyIssue ? PACKAGE_RMR_PENDING : PACKAGE_UNDER_REVIEW,
            AI_Narrative__c = null
        );

        run.Status__c = RUN_COMPLETED;
        run.Classification_Processing_Status__c = 'Completed';
        run.Overall_Result__c = anyIssue ? RESULT_NEEDS_REVIEW : RESULT_PASSED;
        run.Issue_Summary__c = anyIssue ? String.join(summary, '\n').left(32768) : null;
        run.Ended_At__c = System.now();
        update run;

        // Both start only after this transaction commits.
        if (anyIssue) {
            System.enqueueJob(new DNAMS_PackageNarrativeQueueable(runId)); // steps 17 -> 18-20
        } else {
            System.enqueueJob(new DNAMS_ExtractionStarterQueueable(runId)); // steps 22 -> 23
        }
    }

    // ------------------------------------------------------------------ Step 19: owner check + notification

    /** Owner is a user with the DNAMS RMR permission -> email; queue-owned or anyone else -> recorded on the run only. */
    public static void notifyOwners(Map<Id, AI_Package_Review_Run__c> runsByPackage, String subjectSuffix, String body) {
        Map<Id, DNAMS_Package__c> packages = new Map<Id, DNAMS_Package__c>(
            [SELECT Id, Name, Package_Name__c, OwnerId, Buying_Dealer__r.Name FROM DNAMS_Package__c WHERE Id IN :runsByPackage.keySet()]
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
        update notes;
    }

    private static Set<Id> rmrUserIds(Set<Id> candidateIds) {
        Set<Id> userIds = new Set<Id>();
        for (Id candidate : candidateIds) {
            if (candidate != null && candidate.getSobjectType() == User.SObjectType) {
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
        ]) {
            rmr.add(assignment.AssigneeId);
        }
        return rmr;
    }

    private static AI_Package_Review_Run__c appendReason(AI_Package_Review_Run__c run, String text) {
        String existing = [SELECT Reason__c FROM AI_Package_Review_Run__c WHERE Id = :run.Id].Reason__c;
        return new AI_Package_Review_Run__c(Id = run.Id, Reason__c = ((String.isBlank(existing) ? '' : existing + '\n') + text).left(4000));
    }

    // ------------------------------------------------------------------ Run status helpers

    /**
     * Returns the run (locked) when it is still Running; otherwise settles a cancellation and returns null.
     * A deleted run also returns null, so queued work for it stops quietly.
     */
    public static AI_Package_Review_Run__c lockRun(Id runId) {
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, Package__c, Status__c, Classification_Processing_Status__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
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
            update run;
        }
        return null;
    }

    public static Boolean isRunning(Id runId) {
        List<AI_Package_Review_Run__c> runs = [SELECT Status__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
        return !runs.isEmpty() && runs[0].Status__c == RUN_RUNNING;
    }

    public static void failRun(Id runId, Exception e) {
        update new AI_Package_Review_Run__c(
            Id = runId,
            Status__c = RUN_FAILED,
            Classification_Processing_Status__c = 'Failed',
            Ended_At__c = System.now(),
            Error__c = (e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()).left(32768)
        );
    }

    public class PipelineException extends Exception {
    }
}