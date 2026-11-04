/**
 * Runs the dealer upload link flow as the real DNAMS Dealer Portal site guest user, so missing guest
 * permissions fail here instead of on the dealer's screen.
 */
@IsTest
private class DNAMS_GuestAccessTest {
    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true, Instructions__c = 'All fields'),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2)
        };
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id);
    }

    private static User guestUser() {
        return [SELECT Id FROM User WHERE Profile.Name = 'DNAMS Dealer Portal Profile' AND IsActive = TRUE LIMIT 1];
    }

    /** Real guest uploads go through lightning-file-upload, which owns the file; tests insert it the same way. */
    private static void platformUpload(Id elementId, String token, String title) {
        insert new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf(title),
            DNAMS_Upload_Token_fileupload__c = elementId + ':' + token
        );
    }

    @IsTest
    static void guestCanOpenUploadRemoveAndSubmit() {
        DNAMS_Package__c pkg = [SELECT Upload_Token__c FROM DNAMS_Package__c LIMIT 1];
        Id elementId = [SELECT Id FROM DNAMS_Package_Element__c WHERE Name = 'Dealer Application'].Id;
        User guest = guestUser();

        System.runAs(guest) {
            DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c);
            Assert.areEqual(2, view.elements.size());
            Assert.areEqual('All fields', view.elements[0].instructions);
            Assert.isTrue(view.isEditable);
        }

        platformUpload(elementId, pkg.Upload_Token__c, 'application');

        System.runAs(guest) {
            DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c);
            Assert.areEqual(1, view.elements[0].documents.size());
            DNAMS_GuestUploadController.removeDocument(pkg.Upload_Token__c, view.elements[0].documents[0].id);
            Assert.areEqual(0, DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c).elements[0].documents.size());
        }

        platformUpload(elementId, pkg.Upload_Token__c, 'application2');

        System.runAs(guest) {
            DNAMS_GuestUploadController.submitPackage(pkg.Upload_Token__c);
            Assert.isFalse(DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c).isEditable);
        }
        Assert.areEqual('Dealer Submitted', [SELECT Status__c FROM DNAMS_Package__c LIMIT 1].Status__c);
    }
}