/**
 * @description     Tests for DNAMSEmailSender: a verified org-wide address matching the setting becomes the sender;
 *                  a blank, unknown or unverified address leaves the email unchanged.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-09
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-09   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSEmailSenderTest {
    /**
     * @description Points the pipeline settings at the given sender address and clears the helper cache.
     * @param address Sender address to configure (may be blank)
     **/
    private static void useSender(String address) {
        DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
        setting.SenderEmailAddress__c = address;
        DNAMS_PackageReviewPipelineService.settingsOverride = setting;
        DNAMSEmailSender.resetCache();
    }

    /**
     * @description A new plain email for the tests.
     * @return The email
     **/
    private static Messaging.SingleEmailMessage newEmail() {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ 'dealer@example.com' });
        email.setSubject('Test');
        email.setPlainTextBody('Body');
        return email;
    }

    @IsTest
    static void verifiedAddressBecomesTheSender() {
        List<OrgWideEmailAddress> verified = [
            SELECT Id, Address
            FROM OrgWideEmailAddress
            WHERE IsVerified = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        // OrgWideEmailAddress cannot be inserted in a test, so this relies on the org's own verified addresses.
        useSender(verified.isEmpty() ? null : verified[0].Address.toUpperCase());
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>{ newEmail(), newEmail() };

        Test.startTest();
        DNAMSEmailSender.applySender(emails);
        Test.stopTest();

        Id expected = verified.isEmpty() ? null : verified[0].Id;
        for (Messaging.SingleEmailMessage email : emails) {
            Assert.areEqual(expected, email.getOrgWideEmailAddressId(), 'Every email is sent from the verified address');
        }
    }

    @IsTest
    static void unverifiedAddressIsSkipped() {
        List<OrgWideEmailAddress> unverified = [
            SELECT Address
            FROM OrgWideEmailAddress
            WHERE IsVerified = FALSE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        useSender(unverified.isEmpty() ? 'nobody@example.invalid' : unverified[0].Address);
        Messaging.SingleEmailMessage email = newEmail();

        Test.startTest();
        DNAMSEmailSender.applySender(email);
        Test.stopTest();

        Assert.isNull(email.getOrgWideEmailAddressId(), 'An unverified address is never used');
    }

    @IsTest
    static void unknownOrBlankAddressLeavesEmailUnchanged() {
        Messaging.SingleEmailMessage unknown = newEmail();
        Messaging.SingleEmailMessage blank = newEmail();

        Test.startTest();
        useSender('nobody@example.invalid');
        DNAMSEmailSender.applySender(unknown);
        useSender(null);
        DNAMSEmailSender.applySender(blank);
        DNAMSEmailSender.applySender((List<Messaging.SingleEmailMessage>) null);
        Test.stopTest();

        Assert.isNull(unknown.getOrgWideEmailAddressId(), 'No matching address, no sender change');
        Assert.isNull(blank.getOrgWideEmailAddressId(), 'No setting, no sender change');
    }

    @IsTest
    static void senderIsLookedUpOncePerTransaction() {
        useSender('nobody@example.invalid');

        Test.startTest();
        DNAMSEmailSender.applySender(newEmail());
        Integer queriesAfterFirst = Limits.getQueries();
        DNAMSEmailSender.applySender(newEmail());
        DNAMSEmailSender.applySender(newEmail());
        Integer queriesAfterThird = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(queriesAfterFirst, queriesAfterThird, 'The sender is cached after the first lookup');
    }
}
