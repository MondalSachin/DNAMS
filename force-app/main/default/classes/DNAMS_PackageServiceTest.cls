@IsTest
private class DNAMS_PackageServiceTest {
    private static final String TERM_RENEWAL = 'Term Renewal';
    private static final String BUY_SELL = 'Buy/Sell change of Ownership';
    private static final String PRINCIPAL_CHANGE = 'Dealer Principal Change';

    @TestSetup
    static void setup() {
        Account buying = new Account(Name = 'Buying Dealer', AccountNumber = 'TCE00087');
        Account selling = new Account(Name = 'Selling Dealer', AccountNumber = 'IL081');
        insert new List<Account>{ buying, selling };
        insert new Contact(LastName = 'Principal', AccountId = buying.Id, Email = 'principal@example.com');

        DNAMS_Element_Type__c orgChart = new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true);
        DNAMS_Element_Type__c application = new DNAMS_Element_Type__c(
            Name = 'Dealer Application',
            Instructions__c = 'All fields are completed.',
            Sort_Order__c = 1,
            Is_Required__c = true
        );
        DNAMS_Element_Type__c misc = new DNAMS_Element_Type__c(Name = 'Miscellaneous Documents', Sort_Order__c = 3);
        DNAMS_Element_Type__c retired = new DNAMS_Element_Type__c(Name = 'Retired Type', Sort_Order__c = 4, Is_Active__c = false);
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>{ orgChart, application, misc, retired };
        insert types;

        // Term Renewal mirrors the types; the Retired Type mapping is active but its Element Type is not.
        DNAMSPipelineTestHelper.mapElementTypes(TERM_RENEWAL, types);
        DNAMS_Package_Type_Element_Map__c retiredMapping = [
            SELECT Id
            FROM DNAMS_Package_Type_Element_Map__c
            WHERE Package_Type__c = :TERM_RENEWAL AND Element_Type__c = :retired.Id
        ];
        update new DNAMS_Package_Type_Element_Map__c(Id = retiredMapping.Id, Is_Active__c = true, Is_Required__c = true);
        // Buy/Sell: required flags differ from the types, Org Chart is mapped but inactive. Dealer Principal Change: none.
        insert new List<DNAMS_Package_Type_Element_Map__c>{
            new DNAMS_Package_Type_Element_Map__c(Package_Type__c = BUY_SELL, Element_Type__c = application.Id, Is_Active__c = true, Is_Required__c = false),
            new DNAMS_Package_Type_Element_Map__c(Package_Type__c = BUY_SELL, Element_Type__c = misc.Id, Is_Active__c = true, Is_Required__c = true),
            new DNAMS_Package_Type_Element_Map__c(Package_Type__c = BUY_SELL, Element_Type__c = orgChart.Id, Is_Active__c = false, Is_Required__c = true)
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
    static void insertInDraftCreatesElements() {
        DNAMS_Package__c draft = newPackage(TERM_RENEWAL, 'Draft');

        List<DNAMS_Package_Element__c> draftElements = elements(draft.Id);
        Assert.areEqual('Draft', draft.Status__c);
        Assert.areEqual(3, draftElements.size(), 'Elements exist right after a Draft insert');
        Assert.areEqual('Dealer Application', draftElements[0].Name);
    }

    @IsTest
    static void insertCreatesOwnElementsOnceAndInitiatedDoesNotDuplicate() {
        DNAMS_Package__c first = newPackage(TERM_RENEWAL, 'Draft');
        DNAMS_Package__c second = newPackage(TERM_RENEWAL, 'Initiated');

        update new DNAMS_Package__c(Id = first.Id, Status__c = 'Initiated');
        update new DNAMS_Package__c(Id = first.Id, Status__c = 'Returned');
        update new DNAMS_Package__c(Id = first.Id, Status__c = 'Initiated');

        List<DNAMS_Package_Element__c> firstElements = elements(first.Id);
        Assert.areEqual(3, firstElements.size(), 'Inactive types are skipped; no duplicates on Initiated or re-initiate');
        Assert.areEqual('Dealer Application', firstElements[0].Name);
        Assert.isTrue(firstElements[0].Is_Required__c);
        Assert.areEqual(3, elements(second.Id).size(), 'Each package gets its own new elements');
        Assert.areNotEqual(firstElements[0].Id, elements(second.Id)[0].Id);
    }

    @IsTest
    static void elementsComeFromActiveMappingsOfThePackageType() {
        DNAMS_Package__c buySell = newPackage(BUY_SELL, 'Initiated');

        List<DNAMS_Package_Element__c> buySellElements = elements(buySell.Id);
        Assert.areEqual(2, buySellElements.size(), 'Only active Buy/Sell mappings; the inactive Org Chart mapping is skipped');
        Assert.areEqual('Dealer Application', buySellElements[0].Name, 'Ordered by Element Type Sort Order');
        Assert.isFalse(buySellElements[0].Is_Required__c, 'Required comes from the mapping, not the Element Type');
        Assert.areEqual('Miscellaneous Documents', buySellElements[1].Name);
        Assert.isTrue(buySellElements[1].Is_Required__c, 'Required comes from the mapping, not the Element Type');
        Assert.areEqual(1, [SELECT COUNT() FROM DNAMS_Package_Element__c WHERE Package__c = :buySell.Id AND Sort_Order__c = 3], 'Sort Order comes from the Element Type');
    }

    @IsTest
    static void inactiveElementTypeIsExcludedEvenWhenMapped() {
        DNAMS_Package__c pkg = newPackage(TERM_RENEWAL, 'Initiated');
        Assert.areEqual(0, [SELECT COUNT() FROM DNAMS_Package_Element__c WHERE Package__c = :pkg.Id AND Name = 'Retired Type'], 'Inactive Element Type is skipped');
    }

    @IsTest
    static void insertWithTypeWithoutActiveMappingsFails() {
        DNAMS_Package__c pkg = new DNAMS_Package__c(Type__c = PRINCIPAL_CHANGE, Status__c = 'Draft', Buying_Dealer__c = dealer('TCE00087').Id);
        Database.SaveResult result = Database.insert(pkg, false);
        Assert.isFalse(result.isSuccess(), 'No mapping for the type blocks the insert');
        Assert.areEqual('No active elements are mapped for package type ' + PRINCIPAL_CHANGE + '.', result.getErrors()[0].getMessage());
        Assert.areEqual(0, [SELECT COUNT() FROM DNAMS_Package__c WHERE Type__c = :PRINCIPAL_CHANGE]);
    }

    @IsTest
    static void oldDraftPackageWithoutElementsGetsThemAtInitiated() {
        // Simulates a package created before elements were made on insert: Draft with no elements.
        DNAMS_Package__c draft = newPackage(TERM_RENEWAL, 'Draft');
        delete [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c = :draft.Id];
        Assert.areEqual(0, elements(draft.Id).size());

        update new DNAMS_Package__c(Id = draft.Id, Status__c = 'Initiated');

        List<DNAMS_Package_Element__c> created = elements(draft.Id);
        Assert.areEqual(3, created.size(), 'Initiated creates the missing elements');
        Assert.areEqual('Dealer Application', created[0].Name);
    }

    @IsTest
    static void oldDraftPackageWithoutMappingsIsBlockedAtInitiated() {
        DNAMS_Package__c draft = newPackage(TERM_RENEWAL, 'Draft');
        delete [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c = :draft.Id];
        List<DNAMS_Package_Type_Element_Map__c> mappings = [SELECT Id FROM DNAMS_Package_Type_Element_Map__c WHERE Package_Type__c = :TERM_RENEWAL];
        for (DNAMS_Package_Type_Element_Map__c mapping : mappings) {
            mapping.Is_Active__c = false;
        }
        update mappings;

        Database.SaveResult result = Database.update(new DNAMS_Package__c(Id = draft.Id, Status__c = 'Initiated'), false);
        Assert.isFalse(result.isSuccess(), 'No active mapping for the type blocks Initiated');
        Assert.areEqual('No active elements are mapped for package type ' + TERM_RENEWAL + '.', result.getErrors()[0].getMessage());
        Assert.areEqual('Draft', reload(draft.Id).Status__c);
    }

    @IsTest
    static void bulkInitiateAcrossPackageTypes() {
        Id buyingId = dealer('TCE00087').Id;
        List<DNAMS_Package__c> packages = new List<DNAMS_Package__c>{
            new DNAMS_Package__c(Type__c = TERM_RENEWAL, Status__c = 'Initiated', Buying_Dealer__c = buyingId),
            new DNAMS_Package__c(Type__c = BUY_SELL, Status__c = 'Initiated', Buying_Dealer__c = buyingId, Selling_Dealer__c = dealer('IL081').Id),
            new DNAMS_Package__c(Type__c = PRINCIPAL_CHANGE, Status__c = 'Initiated', Buying_Dealer__c = buyingId)
        };
        Test.startTest();
        List<Database.SaveResult> results = Database.insert(packages, false);
        Test.stopTest();

        Assert.isTrue(results[0].isSuccess() && results[1].isSuccess(), 'Mapped types save');
        Assert.isFalse(results[2].isSuccess(), 'The unmapped type fails on its own');
        Assert.areEqual(3, elements(packages[0].Id).size());
        Assert.areEqual(2, elements(packages[1].Id).size());
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

    @IsTest
    static void createCopiesPrimaryContactEmailUnlessFilled() {
        Account buying = [SELECT Id FROM Account WHERE Name = 'Buying Dealer'];
        Contact principal = [SELECT Id FROM Contact WHERE Email = 'principal@example.com'];
        Contact noEmail = new Contact(LastName = 'No Email', AccountId = buying.Id);
        insert noEmail;
        DNAMS_Package__c copied = new DNAMS_Package__c(Type__c = 'Term Renewal', Buying_Dealer__c = buying.Id, Primary_Contact__c = principal.Id);
        DNAMS_Package__c kept = new DNAMS_Package__c(
            Type__c = 'Term Renewal', Buying_Dealer__c = buying.Id, Primary_Contact__c = principal.Id, Upload_Link_Sent_To__c = 'other@example.com'
        );
        DNAMS_Package__c blank = new DNAMS_Package__c(Type__c = 'Term Renewal', Buying_Dealer__c = buying.Id, Primary_Contact__c = noEmail.Id);
        insert new List<DNAMS_Package__c>{ copied, kept, blank };

        Map<Id, DNAMS_Package__c> saved = new Map<Id, DNAMS_Package__c>(
            [SELECT Upload_Link_Sent_To__c FROM DNAMS_Package__c WHERE Id IN :new List<Id>{ copied.Id, kept.Id, blank.Id }]
        );
        Assert.areEqual('principal@example.com', saved.get(copied.Id).Upload_Link_Sent_To__c, 'Contact email is copied on create');
        Assert.areEqual('other@example.com', saved.get(kept.Id).Upload_Link_Sent_To__c, 'An entered email is kept');
        Assert.isNull(saved.get(blank.Id).Upload_Link_Sent_To__c, 'No contact email leaves it blank for the send check to ask');
    }
}