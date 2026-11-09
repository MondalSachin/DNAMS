/**
 * @description     Tests for DNAMSNotificationHelper: one email per queue member per run, and no email when the
 *                  queue has no members or nothing is passed.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSNotificationHelperTest {
    private static final String TEST_QUEUE = 'DNAMSNotificationTestQueue';

    /**
     * @description Creates the test queue with the given users as members (setup DML, before runAs).
     * @param members Users to add
     **/
    private static void createQueue(List<User> members) {
        Group queue = new Group(Name = TEST_QUEUE, DeveloperName = TEST_QUEUE, Type = 'Queue');
        insert queue;
        List<GroupMember> memberships = new List<GroupMember>();
        for (User member : members) {
            memberships.add(new GroupMember(GroupId = queue.Id, UserOrGroupId = member.Id));
        }
        insert memberships;
    }

    /**
     * @description Points the pipeline settings at the test queue.
     **/
    private static void useTestQueue() {
        DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
        setting.AdminQueue__c = TEST_QUEUE;
        DNAMS_PackageReviewPipelineService.settingsOverride = setting;
    }

    @IsTest
    static void emailsEveryActiveQueueMember() {
        User admin = DNAMSPipelineTestHelper.getAdminUser();
        User secondAdmin = DNAMSPipelineTestHelper.getAdminUser();
        createQueue(new List<User>{ admin, secondAdmin });
        System.runAs(admin) {
            useTestQueue();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            String packageName = [SELECT Name FROM DNAMS_Package__c WHERE Id = :fixture.packageId].Name;

            Test.startTest();
            DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>{ fixture.runId => 'Extraction failed. Error logs: EL-000001' });
            Test.stopTest();

            List<Messaging.SingleEmailMessage> emails = DNAMSNotificationHelper.sentEmails;
            Assert.areEqual(2, emails.size(), 'One email per queue member');
            Set<Id> recipients = new Set<Id>{ emails[0].getTargetObjectId(), emails[1].getTargetObjectId() };
            Assert.areEqual(new Set<Id>{ admin.Id, secondAdmin.Id }, recipients, 'Each member is emailed');
            Assert.areEqual('Harbor Motors ' + packageName + ': AI review needs attention', emails[0].getSubject(), 'Subject names the package');
            Assert.isTrue(emails[0].getPlainTextBody().contains('EL-000001'), 'Body carries the error log names');
            Assert.isTrue(emails[0].getPlainTextBody().contains('/' + fixture.packageId), 'Body links the package');
        }
    }

    @IsTest
    static void queueWithoutMembersSendsNothing() {
        User admin = DNAMSPipelineTestHelper.getAdminUser();
        createQueue(new List<User>());
        System.runAs(admin) {
            useTestQueue();
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();

            Test.startTest();
            DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>{ fixture.runId => 'Extraction failed.' });
            DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>());
            Test.stopTest();

            Assert.isTrue(DNAMSNotificationHelper.sentEmails.isEmpty(), 'No members, no email');
            Assert.areEqual(0, [SELECT COUNT() FROM AIReviewErrorLog__c], 'A no-op is not an error');
        }
    }

    @IsTest
    static void blankQueueSettingSendsNothing() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
            setting.AdminQueue__c = null;
            DNAMS_PackageReviewPipelineService.settingsOverride = setting;
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();

            Test.startTest();
            DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>{ fixture.runId => 'Extraction failed.' });
            Test.stopTest();

            Assert.isTrue(DNAMSNotificationHelper.sentEmails.isEmpty(), 'No queue configured, no email');
        }
    }
}
