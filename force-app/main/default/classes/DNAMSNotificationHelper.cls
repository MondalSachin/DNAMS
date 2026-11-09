/**
 * @description     Emails the DNAMS Admin Team (active User members of the queue named by
 *                  DNAMS_Pipeline_Setting__mdt.AdminQueue__c) when a review run needs attention (pre-flight file gate or extraction).
 *                  Emails carry a generic message, error log names and the package link only; never raw payloads.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSNotificationHelper {
    private static final String QUEUE_TYPE = 'Queue';
    private static final String SOURCE_CLASS = DNAMSNotificationHelper.class.getName();

    @TestVisible
    private static List<Messaging.SingleEmailMessage> sentEmails = new List<Messaging.SingleEmailMessage>();

    /**
     * @description Sends one email per admin queue member per run. Does nothing when the queue has no active users.
     * @param bodyByRunId Generic message (with error log names) keyed by review run Id
     * @example
     *   DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>{ runId => 'Extraction failed. Error logs: EL-000001' });
     **/
    public static void notifyAdminTeam(Map<Id, String> bodyByRunId) {
        if (bodyByRunId == null || bodyByRunId.isEmpty()) {
            return;
        }
        try {
            List<User> admins = adminUsers();
            if (admins.isEmpty()) {
                return;
            }
            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            for (AI_Package_Review_Run__c run : [
                SELECT Id, Package__c, Package__r.Name
                FROM AI_Package_Review_Run__c
                WHERE Id IN :bodyByRunId.keySet()
                WITH SYSTEM_MODE
            ]) {
                for (User admin : admins) {
                    emails.add(buildEmail(admin.Id, run, bodyByRunId.get(run.Id)));
                }
            }
            sentEmails.addAll(emails);
            Messaging.sendEmail(emails, false);
        } catch (Exception e) {
            // No run Id: a notification failure must not fail a run that has already completed.
            DNAMSErrorLogHelper.logException(e, null, SOURCE_CLASS);
        }
    }

    /**
     * @description Active users who are direct members of the configured admin queue.
     * @return The admin users (empty when the queue is not configured or has no members)
     **/
    private static List<User> adminUsers() {
        String queueName = DNAMS_PackageReviewPipelineService.settings().AdminQueue__c;
        if (String.isBlank(queueName)) {
            return new List<User>();
        }
        return [
            SELECT Id
            FROM User
            WHERE
                IsActive = TRUE
                AND Id IN (SELECT UserOrGroupId FROM GroupMember WHERE Group.Type = :QUEUE_TYPE AND Group.DeveloperName = :queueName)
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Builds the admin email for one user and run.
     * @param userId The admin user to email
     * @param run    The run, with Package__r.Name
     * @param body   The generic message for the run
     * @return The email
     **/
    private static Messaging.SingleEmailMessage buildEmail(Id userId, AI_Package_Review_Run__c run, String body) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setTargetObjectId(userId);
        email.setSaveAsActivity(false);
        email.setSubject('Harbor Motors ' + run.Package__r.Name + ': AI review needs attention');
        email.setPlainTextBody(
            (body ?? '') + '\n\nOpen the package: ' + URL.getOrgDomainUrl().toExternalForm() + '/' + run.Package__c
        );
        return email;
    }
}
