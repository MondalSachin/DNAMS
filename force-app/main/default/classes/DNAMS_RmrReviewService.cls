/**
 * RMR actions behind the standard Quick Action buttons (screen flows -> invocable actions):
 * Cancel / Re-run review (step 1b) and Return to Dealer (step 21). Every action requires the DNAMS_RMR custom
 * permission and returns a message for the flow screen.
 */
public with sharing class DNAMS_RmrReviewService {
    private static final Set<String> POST_SUBMIT_STATUSES = new Set<String>{
        DNAMS_PackageService.STATUS_DEALER_SUBMITTED,
        DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING,
        DNAMS_PackageReviewPipelineService.PACKAGE_UNDER_REVIEW
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
        result.canCancel = result.isRmr && active && result.latestRun.Status__c != DNAMS_PackageReviewPipelineService.RUN_CANCELLING;
        result.canRerun = result.isRmr && !active && postSubmit;
        result.canReturn = result.canRerun;
        result.unavailableReason = active
            ? 'review ' + result.latestRun.Name + ' is ' + result.latestRun.Status__c + ' (wait for it to finish or cancel it first).'
            : 'the package status is ' + pkg.Status__c + '; it must be Dealer Submitted, RMR Pending or Under Review.';
        return result;
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

    public static String rerunReview(Id packageId) {
        requireRmr();
        Availability state = availability(packageId);
        if (!state.canRerun) {
            throw new RmrException('Re-run is not available: ' + state.unavailableReason);
        }
        DNAMS_PackageReviewPipelineService.requestRerun(packageId);
        return 'A new AI review was requested. It appears in AI Review Runs within a minute.';
    }

    /** Step 21: status -> Returned and the dealer gets the upload link with what to fix. */
    public static String returnToDealer(Id packageId, String recipientEmail) {
        requireRmr();
        Availability state = availability(packageId);
        if (!state.canReturn) {
            throw new RmrException('Return to Dealer is not available: ' + state.unavailableReason);
        }
        if (String.isBlank(recipientEmail)) {
            throw new RmrException('Enter the dealer email address.');
        }
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

        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ recipientEmail });
        message.setSubject('Action required: package ' + pkg.Name + ' was returned for corrections');
        message.setPlainTextBody(
            'Hello,\n\nPackage ' + pkg.Name + ' (' + pkg.Package_Name__c + ')' +
                (pkg.Buying_Dealer__r == null ? '' : ' for ' + pkg.Buying_Dealer__r.Name) +
                ' was returned for corrections.\n\n' +
                (String.isBlank(pkg.AI_Narrative__c) ? '' : DNAMS_PackageNarrativeQueueable.AI_LABEL + '\n' + pkg.AI_Narrative__c + '\n\n') +
                (issues.isEmpty() ? '' : 'What to fix:\n' + String.join(issues, '\n') + '\n\n') +
                'Open this link, replace or add the documents, and click Submit Package again:\n' +
                DNAMS_PackageController.uploadLink(pkg.Upload_Token__c) + '\n\nThank you.'
        );
        message.setSaveAsActivity(false);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });

        Database.update(
            new DNAMS_Package__c(
                Id = pkg.Id,
                Status__c = DNAMS_PackageService.STATUS_RETURNED,
                Upload_Link_Sent_To__c = recipientEmail,
                Upload_Link_Sent_At__c = System.now()
            ),
            AccessLevel.USER_MODE
        );
        return 'Package ' + pkg.Name + ' was returned. The upload link and the list of issues were emailed to ' + recipientEmail + '.';
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