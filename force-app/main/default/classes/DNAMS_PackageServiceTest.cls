@IsTest
private class DNAMS_PackageServiceTest {
    private static final String TERM_RENEWAL = 'Term Renewal';
    private static final String BUY_SELL = 'Buy/Sell change of Ownership';

    @TestSetup
    static void setup() {
        Account buying = new Account(Name = 'Buying Dealer', AccountNumber = 'TCE00087');
        Account selling = new Account(Name = 'Selling Dealer', AccountNumber = 'IL081');
        insert new List<Account>{ buying, selling };
        insert new Contact(LastName = 'Principal', AccountId = buying.Id, Email = 'principal@example.com');

        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Instructions__c = 'All fields are completed.', Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Miscellaneous Documents', Sort_Order__c = 3),
            new DNAMS_Element_Type__c(Name = 'Retired Type', Sort_Order__c = 4, Is_Active__c = false)
        };
    }

    private static Account dealer(String code) {
        return [SELECT Id FROM Account WHERE AccountNumber = :code];
    }

    private static DNAMS_Package__c newPackage(String type, String status) {
        DNAMS_Package__c pkg = new DNAMS_Package__c(
            Type__c = type,
            Status__c = status,
            Buying_Dealer__c = dealer('TCE00087').Id,
            Selling_Dealer__c = type == BUY_SELL ? dealer('IL081').Id : null
        );
        insert pkg;
        return reload(pkg.Id);
    }

    private static DNAMS_Package__c reload(Id packageId) {
        return [
            SELECT Id, Name, Package_Name__c, Status__c, OwnerId, Upload_Token__c, Upload_Link_Sent_To__c
            FROM DNAMS_Package__c
            WHERE Id = :packageId
        ];
    }

    private static List<DNAMS_Package_Element__c> elements(Id packageId) {
        return [
            SELECT Id, Name, Is_Required__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :packageId
            ORDER BY Sort_Order__c
        ];
    }

    private static Id guestUpload(Id elementId, String token) {
        ContentVersion version = new ContentVersion(
            Title = 'doc',
            PathOnClient = 'doc.pdf',
            VersionData = Blob.valueOf('content'),
            DNAMS_Upload_Token_fileupload__c = elementId + ':' + token
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    // ------------------------------------------------------------------ package rules

    @IsTest
    static void namesPackageAndGeneratesUniqueToken() {
        DNAMS_Package__c term = newPackage(TERM_RENEWAL, 'Draft');
        DNAMS_Package__c buySell = newPackage(BUY_SELL, 'Draft');

        Assert.areEqual('TCE00087 - Term Renewal', term.Package_Name__c);
        Assert.areEqual('TCE00087 - Buy/Sell change of Ownership - IL081', buySell.Package_Name__c);
        Assert.areEqual(64, term.Upload_Token__c.length());
        Assert.areNotEqual(term.Upload_Token__c, buySell.Upload_Token__c);
    }

    @IsTest
    static void buySellRequiresSellingDealer() {
        DNAMS_Package__c pkg = new DNAMS_Package__c(Type__c = BUY_SELL, Buying_Dealer__c = dealer('TCE00087').Id);
        Database.SaveResult result = Database.insert(pkg, false);
        Assert.isFalse(result.isSuccess());
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Selling Dealer is required'));
    }

    @IsTest
    static void initiatedCreatesOwnElementsFromActiveTypesOnce() {
        DNAMS_Package__c first = newPackage(TERM_RENEWAL, 'Initiated');
        DNAMS_Package__c second = newPackage(TERM_RENEWAL, 'Initiated');

        update new DNAMS_Package__c(Id = first.Id, Status__c = 'Returned');
        update new DNAMS_Package__c(Id = first.Id, Status__c = 'Initiated');

        List<DNAMS_Package_Element__c> firstElements = elements(first.Id);
        Assert.areEqual(3, firstElements.size(), 'Inactive types are skipped; no duplicates on re-initiate');
        Assert.areEqual('Dealer Application', firstElements[0].Name);
        Assert.isTrue(firstElements[0].Is_Required__c);
        Assert.areEqual(3, elements(second.Id).size(), 'Each package gets its own new elements');
        Assert.areNotEqual(firstElements[0].Id, elements(second.Id)[0].Id);
    }

    @IsTest
    static void overrideAllowsSubmitWithoutDocuments() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        update new DNAMS_Package__c(Id = pkg.Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Assert.areEqual('Dealer Submitted', reload(pkg.Id).Status__c);
    }

    @IsTest
    static void submitWithoutElementsIsBlocked() {
        DNAMS_Package__c pkg = new DNAMS_Package__c(Type__c = TERM_RENEWAL, Status__c = 'Dealer Submitted', Buying_Dealer__c = dealer('TCE00087').Id);
        Database.SaveResult result = Database.insert(pkg, false);
        Assert.isTrue(result.getErrors()[0].getMessage().contains('no elements'));
    }

    @IsTest
    static void submitFromDraftIsBlocked() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Draft');
        Database.SaveResult result = Database.update(new DNAMS_Package__c(Id = pkg.Id, Status__c = 'Dealer Submitted'), false);
        Assert.areEqual(DNAMS_PackageService.SUBMIT_FROM_MESSAGE, result.getErrors()[0].getMessage());
    }

    // ------------------------------------------------------------------ guest upload + submit

    @IsTest
    static void guestUploadsThenSubmits() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        List<DNAMS_Package_Element__c> els = elements(pkg.Id);
        guestUpload(els[0].Id, pkg.Upload_Token__c);

        DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c);
        Assert.areEqual(3, view.elements.size());
        Assert.areEqual('doc.pdf', view.elements[0].documents[0].name);
        Assert.areEqual('All fields are completed.', view.elements[0].instructions);
        Assert.isTrue(view.isEditable);

        try {
            DNAMS_GuestUploadController.submitPackage(pkg.Upload_Token__c);
            Assert.fail('Expected missing-document error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Org Chart'), e.getMessage());
            Assert.isFalse(e.getMessage().contains('Dealer Application'), e.getMessage());
        }

        guestUpload(els[1].Id, pkg.Upload_Token__c);
        DNAMS_GuestUploadController.submitPackage(pkg.Upload_Token__c);

        DNAMS_Package__c submitted = reload(pkg.Id);
        Assert.areEqual('Dealer Submitted', submitted.Status__c);
        Assert.areEqual([SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'CENTRAL_RMR'].Id, submitted.OwnerId);
        Assert.isFalse(DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c).isEditable);

        try {
            DNAMS_GuestUploadController.submitPackage(pkg.Upload_Token__c);
            Assert.fail('Expected already-submitted error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already been submitted'), e.getMessage());
        }
    }

    @IsTest
    static void invalidTokensAreRejected() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        for (String token : new List<String>{ null, 'short', pkg.Upload_Token__c.toUpperCase(), '0'.repeat(64) }) {
            try {
                DNAMS_GuestUploadController.getPackage(token);
                Assert.fail('Expected invalid link for ' + token);
            } catch (AuraHandledException e) {
                Assert.areEqual('This upload link is not valid.', e.getMessage());
            }
        }
    }

    @IsTest
    static void uploadWithWrongTokenOrMalformedValueIsRejected() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        DNAMS_Package__c other = newPackage(TERM_RENEWAL, 'Initiated');
        Id elementId = elements(pkg.Id)[0].Id;

        for (String value : new List<String>{ elementId + ':' + other.Upload_Token__c, 'not-an-id:abc', 'garbage' }) {
            ContentVersion version = new ContentVersion(
                Title = 'doc',
                PathOnClient = 'doc.pdf',
                VersionData = Blob.valueOf('x'),
                DNAMS_Upload_Token_fileupload__c = value
            );
            Database.SaveResult result = Database.insert(version, false);
            Assert.isFalse(result.isSuccess(), value);
            Assert.areEqual(DNAMS_PackageService.INVALID_UPLOAD_MESSAGE, result.getErrors()[0].getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :elementId]);
    }

    @IsTest
    static void documentsLockedAfterSubmit() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        Id elementId = elements(pkg.Id)[2].Id;
        Id documentId = guestUpload(elementId, pkg.Upload_Token__c);
        update new DNAMS_Package__c(Id = pkg.Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');

        List<ContentVersion> attempts = new List<ContentVersion>{
            new ContentVersion(Title = 'late', PathOnClient = 'late.pdf', VersionData = Blob.valueOf('x'), DNAMS_Upload_Token_fileupload__c = elementId + ':' + pkg.Upload_Token__c),
            new ContentVersion(ContentDocumentId = documentId, PathOnClient = 'doc.pdf', VersionData = Blob.valueOf('v2')),
            new ContentVersion(Title = 'direct', PathOnClient = 'direct.pdf', VersionData = Blob.valueOf('x'), FirstPublishLocationId = elementId)
        };
        for (ContentVersion attempt : attempts) {
            try {
                insert attempt;
                Assert.fail('Expected locked error');
            } catch (DmlException e) {
                Assert.isTrue(e.getMessage().contains(DNAMS_PackageService.LOCKED_MESSAGE), e.getMessage());
            }
        }
    }

    @IsTest
    static void guestCanRemoveFilesOnlyWhileEditable() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        Id elementId = elements(pkg.Id)[0].Id;
        Id documentId = guestUpload(elementId, pkg.Upload_Token__c);

        DNAMS_GuestUploadController.removeDocument(pkg.Upload_Token__c, documentId);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :elementId]);

        try {
            DNAMS_GuestUploadController.removeDocument(pkg.Upload_Token__c, documentId);
            Assert.fail('Expected not-in-package error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not part of the package'), e.getMessage());
        }

        guestUpload(elementId, pkg.Upload_Token__c);
        Id second = [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :elementId].ContentDocumentId;
        update new DNAMS_Package__c(Id = pkg.Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        try {
            DNAMS_GuestUploadController.removeDocument(pkg.Upload_Token__c, second);
            Assert.fail('Expected locked error');
        } catch (AuraHandledException e) {
            Assert.areEqual(DNAMS_PackageService.LOCKED_MESSAGE, e.getMessage());
        }
    }

    @IsTest
    static void elementFilesAreAlsoAttachedToThePackage() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        List<DNAMS_Package_Element__c> els = elements(pkg.Id);
        Id documentId = guestUpload(els[0].Id, pkg.Upload_Token__c);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pkg.Id AND ContentDocumentId = :documentId]);

        // Same file on a second element: still one package link; removing it from one element keeps it on the package.
        insert new ContentDocumentLink(ContentDocumentId = documentId, LinkedEntityId = els[1].Id, ShareType = 'V');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pkg.Id AND ContentDocumentId = :documentId]);
        delete [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :els[1].Id AND ContentDocumentId = :documentId];
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pkg.Id AND ContentDocumentId = :documentId]);

        DNAMS_GuestUploadController.removeDocument(pkg.Upload_Token__c, documentId);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :pkg.Id AND ContentDocumentId = :documentId]);
    }

    @IsTest
    static void returnedPackageShowsIssuesAndNarrative() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        DNAMS_Package_Element__c element = elements(pkg.Id)[1];
        update new DNAMS_Package_Element__c(Id = element.Id, Element_Narrative__c = 'Missing expected document.');
        update new DNAMS_Package__c(Id = pkg.Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        update new DNAMS_Package__c(Id = pkg.Id, Status__c = 'Returned', AI_Narrative__c = 'Org Chart is missing.');

        DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(pkg.Upload_Token__c);
        Assert.isTrue(view.isReturned);
        Assert.isTrue(view.isEditable);
        Assert.areEqual('Org Chart is missing.', view.narrative);
        Assert.areEqual('Missing expected document.', view.elements[1].issue);
    }

    // ------------------------------------------------------------------ sender (logged-in users)

    @IsTest
    static void senderListsUnsubmittedPackagesAndSendsLink() {
        DNAMS_Package__c open = newPackage(TERM_RENEWAL, 'Initiated');
        DNAMS_Package__c done = newPackage(TERM_RENEWAL, 'Initiated');
        update new DNAMS_Package__c(Id = done.Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');

        List<DNAMS_PackageController.PackageRow> rows = DNAMS_PackageController.getUnsubmittedPackages();
        Assert.areEqual(1, rows.size());
        Assert.areEqual(open.Id, rows[0].id);
        Assert.isTrue(rows[0].uploadLink.endsWith('/?token=' + open.Upload_Token__c), rows[0].uploadLink);

        Test.startTest();
        DNAMS_PackageController.sendUploadLink(open.Id, 'dealer@example.com');
        Test.stopTest();
        Assert.areEqual('dealer@example.com', reload(open.Id).Upload_Link_Sent_To__c);

        try {
            DNAMS_PackageController.sendUploadLink(done.Id, 'dealer@example.com');
            Assert.fail('Expected already-submitted error');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('already submitted'), e.getMessage());
        }
    }
}