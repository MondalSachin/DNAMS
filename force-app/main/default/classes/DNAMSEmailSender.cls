/**
 * @description     Sets the sender of every outbound DNAMS email to the org-wide email address named by
 *                  DNAMS_Pipeline_Setting__mdt.SenderEmailAddress__c ("Harbor Motors Support"), so emails do not show
 *                  the name of the user who triggered them. Only a verified address is used; when the setting is blank,
 *                  no verified address matches or the lookup fails, the email is left as is and sent as before.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSEmailSender {
    private static Id senderId;
    private static Boolean senderLoaded = false;

    /**
     * @description Sets the org-wide sender on one email (no change when no verified sender is configured).
     * @param email The email to update
     * @example
     *   DNAMSEmailSender.applySender(message);
     *   Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
     **/
    public static void applySender(Messaging.SingleEmailMessage email) {
        applySender(new List<Messaging.SingleEmailMessage>{ email });
    }

    /**
     * @description Sets the org-wide sender on each email (no change when no verified sender is configured).
     * @param emails The emails to update
     **/
    public static void applySender(List<Messaging.SingleEmailMessage> emails) {
        Id orgWideId = loadSenderId();
        if (orgWideId == null || emails == null) {
            return;
        }
        for (Messaging.SingleEmailMessage email : emails) {
            email?.setOrgWideEmailAddressId(orgWideId);
        }
    }

    /**
     * @description The verified org-wide email address matching the setting, looked up once per transaction.
     * @return The OrgWideEmailAddress Id, or null when none is usable
     **/
    private static Id loadSenderId() {
        if (senderLoaded) {
            return senderId;
        }
        senderLoaded = true;
        try {
            String address = DNAMS_PackageReviewPipelineService.settings().SenderEmailAddress__c;
            if (String.isBlank(address)) {
                return null;
            }
            List<OrgWideEmailAddress> matches = [
                SELECT Id
                FROM OrgWideEmailAddress
                WHERE Address = :address.trim() AND IsVerified = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            senderId = matches.isEmpty() ? null : matches[0].Id;
        } catch (Exception e) {
            // The sender is cosmetic: a missing setting or failed lookup must never block an email.
            senderId = null;
        }
        return senderId;
    }

    /**
     * @description Clears the cached sender so a test can change the setting within one transaction.
     **/
    @TestVisible
    private static void resetCache() {
        senderId = null;
        senderLoaded = false;
    }
}
