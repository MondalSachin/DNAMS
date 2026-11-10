/**
 * RMR actions behind the standard Quick Action buttons (screen flows -> invocable actions):
 * Cancel / Re-run review (step 1b) and Initiate Package/Return to Dealer (first upload link email, resend, and step 21 return).
 * Every action requires the DNAMS_RMR custom permission and returns a message for the flow screen.
 */
public with sharing class DNAMS_RmrReviewService {
    private static final Set<String> POST_SUBMIT_STATUSES = new Set<String>{
        DNAMS_PackageService.STATUS_DEALER_SUBMITTED,
        DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW,
        DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED,
        DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED,
        DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING
    };

    public class RmrException extends Exception {
    }

    /** What the RMR can do on a package right now. */
    public class Availability {
        public Boolean isRmr;
        public AI_Package_Review_Run__c latestRun;
        public Boolean canCancel;
        public Boolean canRerun;
        public Boolean canReturn;
        public String unavailableReason;
        public String packageStatus;
    }

    /** Pre-check shown as the first screen of the Re-run / Cancel Review modals. */
    public class ActionCheck {
        public Boolean canProceed = false;
        public String message;
        // Re-run only: what changed since the last run (DNAMSRunChangeDetector.preview); hasChanges false blocks Changes Only.
        public Boolean hasChanges = false;
        public String changePreview;
        public String baselineRunName;
    }

    public static final String ACTION_RERUN = 'Rerun';
    public static final String ACTION_CANCEL = 'Cancel';
    public static final String ACTION_SEND_RETURN = 'SendReturn';

    @TestVisible
    private static final String MISSING_EMAIL =
        'Dealer email seems to be missing. Please fill a valid email in Document Uploading Email, and retry sending.';

    // Field history is not written inside Apex tests, so tests set this instead of the History check.
    @TestVisible
    private static Boolean sentHistoryStub;

    private enum SendMode { SEND, RESEND, RETURN_PACKAGE }

    /** What Initiate Package/Return to Dealer would do on a package now, or why it cannot. */
    private class SendState {
        DNAMS_Package__c pkg;
        SendMode mode;
        String blockedMessage;
    }

    public static Availability availability(Id packageId) {
        Availability result = new Availability();
        result.isRmr = FeatureManagement.checkPermission(DNAMS_PackageReviewPipelineService.RMR_PERMISSION);
        DNAMS_Package__c pkg = [SELECT Status__c FROM DNAMS_Package__c WHERE Id = :packageId WITH USER_MODE];
        List<AI_Package_Review_Run__c> runs = [
            SELECT Id, Name, Status__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :packageId AND Status__c != :DNAMS_PackageReviewPipelineService.RUN_DISCARDED
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Name DESC
            LIMIT 1
        ];
        result.latestRun = runs.isEmpty() ? null : runs[0];
        Boolean active = result.latestRun != null &&
            DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES.contains(result.latestRun.Status__c);
        Boolean postSubmit = POST_SUBMIT_STATUSES.contains(pkg.Status__c);
        result.packageStatus = pkg.Status__c;
        result.canCancel = result.isRmr && active && result.latestRun.Status__c != DNAMS_PackageReviewPipelineService.RUN_CANCELLING;
        result.canRerun = result.isRmr && !active && postSubmit;
        result.canReturn = result.canRerun;
        result.unavailableReason = active
            ? 'review ' + result.latestRun.Name + ' is ' + result.latestRun.Status__c + ' (wait for it to finish or cancel it first).'
            : 'the package status is ' + pkg.Status__c + '; it must be Dealer Submitted, Under Review, Review Failed, Review Passed or RMR Pending.';
        return result;
    }

    /**
     * Checks before the confirmation screen whether a re-run or cancel is possible now, so the modal either asks to
     * confirm or explains straight away why it cannot be done.
     */
    public static ActionCheck checkAction(Id packageId, String action) {
        ActionCheck check = new ActionCheck();
        Availability state = availability(packageId);
        if (!state.isRmr) {
            check.message = 'Only RMR users can do this (DNAMS RMR permission set).';
            return check;
        }
        if (action == ACTION_SEND_RETURN) {
            return checkSendReturn(packageId);
        }
        Boolean active = state.latestRun != null &&
            DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES.contains(state.latestRun.Status__c);
        String runText = active ? 'Review ' + state.latestRun.Name + ' (' + state.latestRun.Status__c + ')' : null;
        if (action == ACTION_CANCEL) {
            check.canProceed = state.canCancel;
            if (state.canCancel) {
                check.message = runText + ' is in progress for this package. Do you want to cancel it? It stops at its next step.';
            } else if (active) {
                check.message = 'Review ' + state.latestRun.Name + ' is already being cancelled. It stops at its next step.';
            } else {
                check.message = 'No AI review is running for this package, so there is nothing to cancel.';
            }
        } else {
            check.canProceed = state.canRerun;
            if (state.canRerun) {
                check.message = 'Do you want to run the AI document review again?';
                addChangePreview(check, packageId);
            } else if (active) {
                check.message = runText + ' is still in progress. Wait for it to finish, or cancel it, before running a new review.';
            } else {
                check.message = 'A review can be re-run only after the dealer has submitted the package. The package status is ' +
                    state.packageStatus + '.';
            }
        }
        return check;
    }

    public static String cancelReview(Id packageId) {
        requireRmr();
        Availability state = availability(packageId);
        if (!state.canCancel) {
            throw new RmrException('There is no review in progress to cancel.');
        }
        DNAMS_PackageReviewPipelineService.cancelActiveRun(packageId);
        return 'Review ' + state.latestRun.Name + ' is being cancelled; it stops at its next step.';
    }

    /**
     * @description Adds the Changes Only preview to a Re-run check. A preview failure only blocks Changes Only.
     * @param check     Re-run check that can proceed
     * @param packageId Package to compare with its last run
     **/
    private static void addChangePreview(ActionCheck check, Id packageId) {
        try {
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId);
            check.hasChanges = preview.hasChanges;
            check.changePreview = preview.text;
            check.baselineRunName = preview.baselineRunName;
        } catch (Exception e) {
            check.hasChanges = false;
            check.changePreview = 'Could not compare with the last run (' + e.getMessage() + '). Use Re-run all.';
        }
    }

    /**
     * @description Re-run with every stage run again (Re-run all).
     * @param packageId Package to re-run
     * @return          Message for the flow screen
     **/
    public static String rerunReview(Id packageId) {
        return rerunReview(packageId, DNAMSPipelineConstants.RERUN_MODE_ALL);
    }

    /**
     * @description Re-run in the chosen mode. Changes Only is refused when nothing changed since the last run
     *              (checked here as well, never trusting the screen).
     * @param packageId Package to re-run
     * @param mode      'Changes Only' or 'All' (blank = All)
     * @return          Message for the flow screen
     **/
    public static String rerunReview(Id packageId, String mode) {
        requireRmr();
        Availability state = availability(packageId);
        if (!state.canRerun) {
            throw new RmrException('Re-run is not available: ' + state.unavailableReason);
        }
        String rerunMode = DNAMSRunChangeDetector.normaliseMode(mode);
        Boolean changesOnly = rerunMode == DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY;
        if (changesOnly) {
            DNAMSRunChangeDetector.Preview preview = DNAMSRunChangeDetector.preview(packageId);
            if (!preview.hasChanges) {
                throw new RmrException(preview.text);
            }
        }
        DNAMS_PackageReviewPipelineService.requestRerun(packageId, rerunMode);
        return changesOnly
            ? 'A new AI review (changes only) was requested. It appears in AI Review Runs within a minute.'
            : 'A new AI review was requested. It appears in AI Review Runs within a minute.';
    }

    /**
     * Initiate Package/Return to Dealer. Draft: emails the upload link and moves the package to Initiated. Initiated: emails the
     * link again. Any later status: only when History shows the package reached Initiated and a link was sent; then
     * step 21 (Returned + link with the AI summary and issues). Always uses Document Uploading Email.
     */
    public static String sendOrReturn(Id packageId) {
        requireRmr();
        SendState state = sendState(packageId);
        if (state.blockedMessage != null) {
            throw new RmrException(state.blockedMessage);
        }
        DNAMS_Package__c pkg = state.pkg;
        String recipient = pkg.Upload_Link_Sent_To__c;
        // The status change goes first and the email last, so a failure leaves neither behind.
        Savepoint savepoint = Database.setSavepoint();
        try {
            if (state.mode == SendMode.RETURN_PACKAGE) {
                returnToDealer(pkg.Id, recipient);
                return 'Package ' + pkg.Name + ' was returned. The upload link and the list of issues were emailed to ' + recipient + '.';
            }
            if (state.mode == SendMode.SEND) {
                Database.update(
                    new DNAMS_Package__c(Id = pkg.Id, Status__c = DNAMS_PackageService.STATUS_INITIATED),
                    AccessLevel.USER_MODE
                );
            }
            DNAMS_PackageController.sendUploadLink(pkg.Id, recipient);
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
        return state.mode == SendMode.SEND
            ? 'The upload link for package ' + pkg.Name + ' was emailed to ' + recipient + '. The package is now Initiated.'
            : 'The upload link for package ' + pkg.Name + ' was emailed again to ' + recipient + '.';
    }

    private static ActionCheck checkSendReturn(Id packageId) {
        ActionCheck check = new ActionCheck();
        SendState state = sendState(packageId);
        if (state.blockedMessage != null) {
            check.message = state.blockedMessage;
            return check;
        }
        DNAMS_Package__c pkg = state.pkg;
        String recipient = pkg.Upload_Link_Sent_To__c;
        check.canProceed = true;
        if (state.mode == SendMode.SEND) {
            check.message = 'Send the upload link for package ' + pkg.Name + ' to ' + recipient + '?';
        } else if (state.mode == SendMode.RESEND && pkg.Upload_Link_Sent_At__c == null) {
            check.message = 'Send the upload link for package ' + pkg.Name + ' to ' + recipient + '?';
        } else if (state.mode == SendMode.RESEND) {
            check.message = 'The upload link was already sent to ' + recipient + ' on ' + pkg.Upload_Link_Sent_At__c.format() +
                '. Do you want to resend it anyway?';
        } else {
            check.message = 'Return package ' + pkg.Name + ' to ' + recipient + ' for corrections?';
        }
        return check;
    }

    private static SendState sendState(Id packageId) {
        SendState state = new SendState();
        state.pkg = [
            SELECT Id, Name, Status__c, Upload_Link_Sent_To__c, Upload_Link_Sent_At__c
            FROM DNAMS_Package__c
            WHERE Id = :packageId
            WITH USER_MODE
        ];
        String status = state.pkg.Status__c;
        if (status == DNAMS_PackageService.STATUS_DRAFT) {
            state.mode = SendMode.SEND;
        } else if (status == DNAMS_PackageService.STATUS_INITIATED) {
            state.mode = SendMode.RESEND;
        } else {
            AI_Package_Review_Run__c latestRun = availability(packageId).latestRun;
            if (latestRun != null && DNAMS_PackageReviewPipelineService.ACTIVE_RUN_STATUSES.contains(latestRun.Status__c)) {
                state.blockedMessage = 'Review ' + latestRun.Name + ' is ' + latestRun.Status__c +
                    '. Wait for it to finish, or cancel it, before returning the package to the dealer.';
                return state;
            }
            if (!sentWhileInitiated(packageId)) {
                state.blockedMessage = 'Package ' + state.pkg.Name + ' cannot be returned: its History does not show it reaching ' +
                    'Initiated with an upload link sent to the dealer. A package can be returned only after that first send.';
                return state;
            }
            state.mode = SendMode.RETURN_PACKAGE;
        }
        if (String.isBlank(state.pkg.Upload_Link_Sent_To__c)) {
            state.blockedMessage = MISSING_EMAIL;
        }
        return state;
    }

    /** History shows the status reaching Initiated, and an upload link email (Sent To or Sent At change). */
    private static Boolean sentWhileInitiated(Id packageId) {
        if (sentHistoryStub != null) {
            return sentHistoryStub;
        }
        Boolean initiated = false;
        Boolean sent = false;
        for (DNAMS_Package__History row : [
            SELECT Field, NewValue
            FROM DNAMS_Package__History
            WHERE ParentId = :packageId AND Field IN ('Status__c', 'Upload_Link_Sent_To__c', 'Upload_Link_Sent_At__c')
            WITH SYSTEM_MODE
        ]) {
            if (row.Field == 'Status__c') {
                initiated = initiated || String.valueOf(row.NewValue) == DNAMS_PackageService.STATUS_INITIATED;
            } else {
                sent = sent || row.NewValue != null;
            }
        }
        return initiated && sent;
    }

    /** Step 21: status -> Returned, then the dealer gets the upload link with what to fix. */
    private static void returnToDealer(Id packageId, String recipientEmail) {
        DNAMS_Package__c pkg = [
            SELECT Id, Name, Package_Name__c, Upload_Token__c, AI_Narrative__c, Buying_Dealer__r.Name,
                (SELECT Name, Element_Narrative__c FROM Package_Elements__r ORDER BY Sort_Order__c)
            FROM DNAMS_Package__c
            WHERE Id = :packageId
            WITH USER_MODE
        ];
        List<String> issues = new List<String>();
        for (DNAMS_Package_Element__c element : pkg.Package_Elements__r) {
            if (String.isNotBlank(element.Element_Narrative__c)) {
                issues.add('- ' + element.Name + ': ' + element.Element_Narrative__c);
            }
        }

        Database.update(
            new DNAMS_Package__c(
                Id = pkg.Id,
                Status__c = DNAMS_PackageService.STATUS_RETURNED,
                Upload_Link_Sent_To__c = recipientEmail,
                Upload_Link_Sent_At__c = System.now()
            ),
            AccessLevel.USER_MODE
        );

        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipientEmail });
        message.setSubject('Harbor Motors: package ' + pkg.Name + ' was returned for corrections');
        message.setPlainTextBody(
            'Hello,\n\nPackage ' + pkg.Name + ' (' + pkg.Package_Name__c + ')' +
                (pkg.Buying_Dealer__r == null ? '' : ' for ' + pkg.Buying_Dealer__r.Name) +
                ' was returned for corrections.\n\n' +
                (String.isBlank(pkg.AI_Narrative__c) ? '' : DNAMS_PackageNarrativeQueueable.AI_LABEL + '\n' + pkg.AI_Narrative__c + '\n\n') +
                (issues.isEmpty() ? '' : 'What to fix:\n' + String.join(issues, '\n') + '\n\n') +
                'Open this link, replace or add the documents, and click Submit Package again:\n' +
                DNAMS_PackageController.uploadLink(pkg.Upload_Token__c) + '\n\nThank you,\nHarbor Motors Dealer Network'
        );
        message.setSaveAsActivity(false);
        DNAMSEmailSender.applySender(message);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
    }

    private static void requireRmr() {
        if (!FeatureManagement.checkPermission(DNAMS_PackageReviewPipelineService.RMR_PERMISSION)) {
            throw new RmrException('Only RMR users can do this (DNAMS RMR permission set).');
        }
    }

    /** Message shown on the flow screen when an action could not be done. */
    public static String failure(Exception e) {
        return 'Not done: ' + e.getMessage();
    }
}