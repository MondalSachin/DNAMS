/**
 * @description     Tests for DNAMSTransmittalPdfController: every readiness issue (no run, running, cancelled, not
 *                  passed, drafting, package status, missing summaries, missing Dealer Application, no access), the
 *                  view model built for a ready package and the page behaviour. Inserts no files: the extraction is
 *                  set directly on the run's ConsolidatedExtractionJSON__c. The PDF itself is not rendered.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-10
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-10   Abhishek Dutta  Initial version
 **/
@IsTest
private class DNAMSTransmittalPdfControllerTest {
    private static final String COMPLETED = DNAMSPipelineConstants.RUN_STAGE_COMPLETED;
    private static final String EXECUTIVE = 'Ridgeline&#39;s review was clean.<br>All checks passed &amp; Green.';
    private static final String OWNERSHIP = '<p>Owned 60% by Marcus.</p><p><b>40%</b> by Ridgeline Auto Group.</p>';
    private static final String DEALER_APPLICATION_JSON =
        '{"DealerApplication":[{"elementType":"Dealer Application","data":{' +
        '"LegalNameOrDealerEntity":"Ridgeline Northstar of Columbus, LLC","TradeName":"Ridgeline Northstar",' +
        '"DealerCode":"40718","RegionOrDistrict":"Great Lakes / D-04","DealershipStreetAddress":"4825 Morse Road",' +
        '"DealershipCity":"Columbus","DealershipState":"OH","DealershipZip":"43230-1561",' +
        '"StateDealerLicenseNumber":"OH-MVD-D1187264","DealerOperatorPrintedName":"Marcus James Whitfield",' +
        '"DealerOperatorPrintedTitle":"President","AuthorizedOfficerOfDealerEntityPrintedName":"Marcus James Whitfield",' +
        '"AuthorizedOfficerOfDealerEntityPrintedTitle":"Managing Member","DealerOperatorSigningDate":"10-14-2026",' +
        '"HasApplicantBeenBankrupt":"No","HasApplicantBeenConvicted":"True","SocialSecurityNumber":"000-48-2917",' +
        '"FederalEIN":"00-4471823","DateOfBirth":"08-23-1972",' +
        '"OwnershipInfoDirectOwners":[{"NameOfOwner":"Marcus James Whitfield","OwnershipPercentage":"60.00",' +
        '"VotingPercentage":"60.00","SSNorEIN":"000-48-2917","DateOfBirth":"08-23-1972"}],' +
        '"OwnershipInfoIndirectOwners":[{"Name":"Gregory Thomas Hollis","HeldThrough":"Ridgeline Auto Group, Inc. (30%)",' +
        '"EffectivePercentageOfDealer":"12.50","SSN":"000-39-1458","DateOfBirth":"05-17-1966"}]}}]}';

    // ------------------------------------------------------------------ fixture helpers

    /**
     * @description Inserts an element type mapped to Term Renewal (packages need elements), a dealer and a package.
     * @param status    Package Status__c
     * @param ownership Ownership_Summary__c
     * @param executive Executive_Summary__c
     * @return The package
     **/
    private static DNAMS_Package__c createPackage(String status, String ownership, String executive) {
        DNAMS_Element_Type__c elementType = new DNAMS_Element_Type__c(Name = 'Dealer Application', Is_Active__c = true, Sort_Order__c = 1);
        insert elementType;
        DNAMSPipelineTestHelper.mapElementTypes('Term Renewal', new List<DNAMS_Element_Type__c>{ elementType });
        Account dealer = new Account(Name = 'Ridgeline Northstar of Columbus, LLC', AccountNumber = '40718');
        insert dealer;
        DNAMS_Package__c pkg = new DNAMS_Package__c(
            Type__c = 'Term Renewal',
            Status__c = status,
            Buying_Dealer__c = dealer.Id,
            Health__c = DNAMSPipelineConstants.HEALTH_GREEN,
            Ownership_Summary__c = ownership,
            Executive_Summary__c = executive
        );
        insert pkg;
        return [SELECT Id, Name FROM DNAMS_Package__c WHERE Id = :pkg.Id];
    }

    /**
     * @description Inserts a review run with every stage Completed (no files).
     * @param packageId      The package
     * @param status         Run Status__c
     * @param overallResult  Overall_Result__c
     * @param extractionJson ConsolidatedExtractionJSON__c
     * @return The run
     **/
    private static AI_Package_Review_Run__c createRun(Id packageId, String status, String overallResult, String extractionJson) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = packageId,
            Status__c = status,
            Overall_Result__c = overallResult,
            Trigger_Source__c = DNAMS_PackageReviewPipelineService.SOURCE_DEALER_SUBMIT,
            Classification_Processing_Status__c = COMPLETED,
            ExtractionProcessingStatus__c = COMPLETED,
            RuleValidationProcessingStatus__c = COMPLETED,
            TransmittalProcessingStatus__c = COMPLETED,
            RuleValidationPassRate__c = 100,
            Started_At__c = System.now().addMinutes(-5),
            Ended_At__c = System.now(),
            ConsolidatedExtractionJSON__c = extractionJson
        );
        insert run;
        return [SELECT Id, Name FROM AI_Package_Review_Run__c WHERE Id = :run.Id];
    }

    /**
     * @description A ready package: Review Passed, both summaries, a Passed run with the Dealer Application.
     * @return The package
     **/
    private static DNAMS_Package__c createReadyPackage() {
        DNAMS_Package__c pkg = createPackage(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED, OWNERSHIP, EXECUTIVE);
        createRun(pkg.Id, DNAMS_PackageReviewPipelineService.RUN_COMPLETED, DNAMS_PackageReviewPipelineService.RESULT_PASSED, DEALER_APPLICATION_JSON);
        return pkg;
    }

    /**
     * @description Opens the PDF page for a package id parameter and returns its controller.
     * @param idParam The id page parameter
     * @return The page controller
     **/
    private static DNAMSTransmittalPdfController openPage(String idParam) {
        PageReference pdfPage = Page.DNAMS_TransmittalPdf;
        pdfPage.getParameters().put('id', idParam);
        Test.setCurrentPage(pdfPage);
        return new DNAMSTransmittalPdfController();
    }

    /**
     * @description Message with the run name filled in.
     * @param template The message template
     * @param runName  The run name
     * @return The message
     **/
    private static String withRun(String template, String runName) {
        return String.format(template, new List<Object>{ runName });
    }

    // ------------------------------------------------------------------ readiness

    @IsTest
    static void readyPackageOffersDownload() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createReadyPackage();
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.isTrue(readiness.ready, 'Ready package: ' + readiness.issues);
            Assert.isTrue(readiness.issues.isEmpty(), 'No issues');
            Assert.isTrue(readiness.downloadUrl.containsIgnoreCase('/apex/DNAMS_TransmittalPdf'), 'Points at the PDF page');
            Assert.isTrue(readiness.downloadUrl.contains(pkg.Id), 'Carries the package id');
        }
    }

    @IsTest
    static void noRunAndNoSummariesListsBoth() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage('Under Review', null, null);
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.isFalse(readiness.ready, 'Not ready');
            Assert.isNull(readiness.downloadUrl, 'No download when not ready');
            Assert.areEqual(
                new List<String>{ DNAMSTransmittalPdfController.MESSAGE_NO_RUN, DNAMSTransmittalPdfController.MESSAGE_SUMMARIES_MISSING },
                readiness.issues,
                'Every unmet item'
            );
        }
    }

    @IsTest
    static void runningRunIsReportedWithoutExtractionCheck() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage('Initiated', OWNERSHIP, EXECUTIVE);
            AI_Package_Review_Run__c run = createRun(pkg.Id, DNAMS_PackageReviewPipelineService.RUN_RUNNING, null, null);
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.areEqual(new List<String>{ withRun(DNAMSTransmittalPdfController.MESSAGE_RUNNING, run.Name) }, readiness.issues, 'Still running');
        }
    }

    @IsTest
    static void cancelledRunIsReported() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage('RMR Pending', OWNERSHIP, EXECUTIVE);
            AI_Package_Review_Run__c run = createRun(pkg.Id, DNAMS_PackageReviewPipelineService.RUN_CANCELLED, null, DEALER_APPLICATION_JSON);
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.areEqual(new List<String>{ withRun(DNAMSTransmittalPdfController.MESSAGE_CANCELLED, run.Name) }, readiness.issues, 'Cancelled');
        }
    }

    @IsTest
    static void failedReviewListsHealthRateSummaryAndExtraction() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_FAILED, OWNERSHIP, null);
            update new DNAMS_Package__c(Id = pkg.Id, Health__c = DNAMSPipelineConstants.HEALTH_AMBER);
            AI_Package_Review_Run__c run = createRun(
                pkg.Id,
                DNAMS_PackageReviewPipelineService.RUN_COMPLETED,
                DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW,
                '{"OrgChart":[{"data":{}}]}'
            );
            update new AI_Package_Review_Run__c(Id = run.Id, RuleValidationPassRate__c = 92.86);
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.areEqual(
                new List<String>{
                    'The latest review ' + run.Name + ' did not pass (Health Amber, rule validation 92%). ' +
                    'All review stages must pass before a transmittal can be generated.',
                    'The Executive Summary has not been drafted yet. Use Draft AI Transmittal first.',
                    withRun(DNAMSTransmittalPdfController.MESSAGE_NO_DEALER_APPLICATION, run.Name)
                },
                readiness.issues,
                'Every unmet item'
            );
        }
    }

    @IsTest
    static void incompleteStageCountsAsNotPassed() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createReadyPackage();
            AI_Package_Review_Run__c run = [SELECT Id, Name FROM AI_Package_Review_Run__c WHERE Package__c = :pkg.Id];
            update new AI_Package_Review_Run__c(Id = run.Id, RuleValidationProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_FAILED);
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness readiness = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.areEqual(1, readiness.issues.size(), 'One issue: ' + readiness.issues);
            Assert.isTrue(readiness.issues[0].startsWith('The latest review ' + run.Name + ' did not pass'), 'Not passed');
        }
    }

    @IsTest
    static void draftingAndPackageStatusAreReported() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createReadyPackage();
            AI_Package_Review_Run__c run = [SELECT Id FROM AI_Package_Review_Run__c WHERE Package__c = :pkg.Id];
            update new AI_Package_Review_Run__c(Id = run.Id, TransmittalProcessingStatus__c = DNAMSPipelineConstants.RUN_STAGE_IN_PROGRESS);
            DNAMSTransmittalPdfController.Readiness drafting = DNAMSTransmittalPdfController.getReadiness(pkg.Id);

            update new AI_Package_Review_Run__c(Id = run.Id, TransmittalProcessingStatus__c = COMPLETED);
            update new DNAMS_Package__c(Id = pkg.Id, Status__c = 'Returned');
            Test.startTest();
            DNAMSTransmittalPdfController.Readiness returned = DNAMSTransmittalPdfController.getReadiness(pkg.Id);
            Test.stopTest();
            Assert.areEqual(new List<String>{ DNAMSTransmittalPdfController.MESSAGE_DRAFTING }, drafting.issues, 'Still drafting');
            Assert.areEqual(new List<String>{ withRun(DNAMSTransmittalPdfController.MESSAGE_STATUS, 'Returned') }, returned.issues, 'Status');
        }
    }

    @IsTest
    static void invisiblePackageThrowsNoAccess() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createReadyPackage();
            Id packageId = pkg.Id;
            delete [SELECT Id FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
            delete [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c = :packageId];
            delete pkg;
            Test.startTest();
            try {
                DNAMSTransmittalPdfController.getReadiness(packageId);
                Assert.fail('Expected an AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.areEqual(DNAMSTransmittalPdfController.MESSAGE_NO_ACCESS, e.getMessage(), 'No access message');
            }
            Test.stopTest();
        }
    }

    // ------------------------------------------------------------------ page and view model

    @IsTest
    static void readyPageBuildsViewAndDownloadHeader() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createReadyPackage();
            Test.startTest();
            DNAMSTransmittalPdfController controller = openPage(pkg.Id);
            Test.stopTest();
            Assert.isTrue(controller.ready, 'Ready: ' + controller.issues);
            DNAMSTransmittalPdfController.TransmittalView view = controller.view;
            Assert.areEqual('Ridgeline Northstar of Columbus, LLC', view.dealerName, 'Dealer name');
            Assert.areEqual('40718', view.dealerCode, 'Dealer code');
            Assert.areEqual('Term Renewal', view.packageType, 'Type');
            Assert.areEqual('100%', view.checksPassed, 'Pass rate');
            Assert.areEqual('Passed', view.overallResult, 'Outcome');
            Assert.areEqual(UserInfo.getName(), view.preparedBy, 'Prepared by the current user');
            Assert.areEqual(DNAMSTransmittalPdfController.PREPARER_TITLE, view.preparerTitle, 'Preparer title');
            Assert.isNull(view.sellingDealerName, 'No selling dealer');
            Assert.areEqual(new List<String>{ 'Ridgeline\'s review was clean.', 'All checks passed & Green.' }, view.executiveParagraphs, 'Decoded once');
            Assert.areEqual(new List<String>{ 'Owned 60% by Marcus.', '40% by Ridgeline Auto Group.' }, view.ownershipParagraphs, 'Markup dropped');
            Assert.areEqual('Columbus, OH 43230-1561', view.cityStateZip, 'Address line');
            Assert.areEqual('No', view.bankruptcy, 'Bankruptcy');
            Assert.areEqual('Yes', view.conviction, 'Conviction');
            Assert.areEqual('President', view.operatorTitle, 'Operator title');
            Assert.areEqual(2, view.owners.size(), 'Direct and indirect owners');
            Assert.areEqual('60%', view.owners[0].ownership, 'Direct ownership');
            Assert.areEqual('60%', view.owners[0].voting, 'Direct voting');
            Assert.areEqual('Indirect', view.owners[1].ownerType, 'Indirect owner');
            Assert.areEqual('Ridgeline Auto Group, Inc. (30%)', view.owners[1].heldThrough, 'Held through');
            Assert.areEqual('12.5%', view.owners[1].ownership, 'Effective percentage');
            Assert.areEqual(DNAMSTransmittalPdfController.DASH, view.owners[1].voting, 'No voting for indirect');
            String serialized = JSON.serialize(view);
            for (String secret : new List<String>{ '000-48-2917', '00-4471823', '08-23-1972', '000-39-1458' }) {
                Assert.isFalse(serialized.contains(secret), 'Never shows SSN, EIN or date of birth');
            }
            String expectedReference = 'TR-' + pkg.Name.substringAfterLast('-') + '-' + Datetime.now().format('yyMMdd');
            Assert.areEqual(expectedReference, controller.reference, 'Reference');
            Assert.areEqual(
                'attachment; filename=Dealer_Transmittal_' + pkg.Name + '.pdf',
                ApexPages.currentPage().getHeaders().get('Content-Disposition'),
                'Download file name'
            );
        }
    }

    @IsTest
    static void notReadyPageShowsIssuesWithoutPdf() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage('Under Review', OWNERSHIP, EXECUTIVE);
            Test.startTest();
            DNAMSTransmittalPdfController controller = openPage(pkg.Id);
            DNAMSTransmittalPdfController invalid = openPage('not-an-id');
            Test.stopTest();
            Assert.isFalse(controller.ready, 'Not ready');
            Assert.isNull(controller.view, 'No document');
            Assert.areEqual(new List<String>{ DNAMSTransmittalPdfController.MESSAGE_NO_RUN }, controller.issues, 'Issues shown');
            Assert.isFalse(invalid.ready, 'Invalid id is not ready');
            Assert.areEqual(new List<String>{ DNAMSTransmittalPdfController.MESSAGE_NO_ACCESS }, invalid.issues, 'Invalid id');
            Assert.isNull(ApexPages.currentPage().getHeaders().get('Content-Disposition'), 'No download header');
        }
    }

    @IsTest
    static void missingExtractionValuesBecomeDashes() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMS_Package__c pkg = createPackage(DNAMS_PackageReviewPipelineService.PACKAGE_REVIEW_PASSED, OWNERSHIP, EXECUTIVE);
            createRun(
                pkg.Id,
                DNAMS_PackageReviewPipelineService.RUN_COMPLETED,
                DNAMS_PackageReviewPipelineService.RESULT_PASSED,
                '{"DealerApplication":[{"data":{"TradeName":"  ","OwnershipInfoDirectOwners":[{"NameOfOwner":"A","OwnershipPercentage":"n/a"}]}}]}'
            );
            Test.startTest();
            DNAMSTransmittalPdfController controller = openPage(pkg.Id);
            Test.stopTest();
            String dash = DNAMSTransmittalPdfController.DASH;
            DNAMSTransmittalPdfController.TransmittalView view = controller.view;
            Assert.isTrue(controller.ready, 'Ready: ' + controller.issues);
            Assert.areEqual(dash, view.legalName, 'Missing legal name');
            Assert.areEqual(dash, view.tradeName, 'Blank trade name');
            Assert.areEqual(dash, view.cityStateZip, 'Missing address');
            Assert.areEqual(dash, view.bankruptcy, 'Missing disclosure');
            Assert.isNull(view.operatorTitle, 'Missing title is left out');
            Assert.areEqual('n/a', view.owners[0].ownership, 'Non-numeric percentage shown as given');
            Assert.areEqual(dash, view.owners[0].voting, 'Missing voting');
        }
    }

    @IsTest
    static void unreadableExtractionIsMissing() {
        Test.startTest();
        Map<String, Object> notJson = DNAMSTransmittalPdfController.dealerApplication('{not json');
        Map<String, Object> notObject = DNAMSTransmittalPdfController.dealerApplication('[1,2]');
        Map<String, Object> emptyList = DNAMSTransmittalPdfController.dealerApplication('{"DealerApplication":[]}');
        Test.stopTest();
        Assert.isNull(notJson, 'Malformed JSON');
        Assert.isNull(notObject, 'Not an object');
        Assert.isNull(emptyList, 'No Dealer Application entry');
    }
}
