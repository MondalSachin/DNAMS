/**
 * A dealer submits as the DNAMS Dealer Portal site guest, whose profile cannot create the review request event.
 * The submit must still start the AI review (regression: DNAP-0003904 sat at Dealer Submitted with no run).
 * No files are inserted: the validation override lets the package submit without documents.
 */
@IsTest
private class DNAMS_GuestSubmitReviewTest {
    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00088');
        insert dealer;
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true)
        };
        insert types;
        DNAMSPipelineTestHelper.mapElementTypes('Term Renewal', types);
        insert new DNAMS_Package__c(
            Type__c = 'Term Renewal',
            Status__c = 'Initiated',
            Buying_Dealer__c = dealer.Id,
            Dealer_Submit_Validation_Override__c = true
        );
    }

    @IsTest
    static void guestSubmitStartsReviewRun() {
        DNAMS_Package__c pkg = [SELECT Id, Upload_Token__c FROM DNAMS_Package__c LIMIT 1];
        User guest = [SELECT Id FROM User WHERE Profile.Name = 'DNAMS Dealer Portal Profile' AND IsActive = TRUE LIMIT 1];

        System.runAs(guest) {
            DNAMS_GuestUploadController.submitPackage(pkg.Upload_Token__c);
        }
        Test.getEventBus().deliver();

        List<AI_Package_Review_Run__c> runs = [
            SELECT Status__c, Trigger_Source__c
            FROM AI_Package_Review_Run__c
            WHERE Package__c = :pkg.Id
        ];
        Assert.areEqual(1, runs.size(), 'A guest submit must publish the review request and create a run');
        Assert.areEqual(DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT, runs[0].Trigger_Source__c);
        Assert.areEqual('Running', runs[0].Status__c);
    }
}
