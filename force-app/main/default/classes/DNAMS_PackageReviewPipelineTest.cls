@IsTest
private class DNAMS_PackageReviewPipelineTest {
    /** Answers by file title: good* matches, wrong* is a bank statement, moderate* unsure, low* low confidence, bad* malformed. */
    private class StubClassifier implements DNAMS_DocumentClassifier {
        Integer calls = 0;

        public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
            calls++;
            String title = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId].Title;
            String expected = [SELECT Name FROM DNAMS_Package_Element__c WHERE Id = :elementId].Name;
            if (title.startsWith('good')) {
                return '```json\n{"matches_expected": true, "document_type": "' + expected + '", "confidence": "FULLY", "reasoning": "clear"}\n```';
            }
            if (title.startsWith('wrong')) {
                return '{"matches_expected": false, "document_type": "Bank Statement", "confidence": "FULLY", "reasoning": "a statement"}';
            }
            if (title.startsWith('moderate')) {
                return '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "MODERATE", "reasoning": "probably"}';
            }
            if (title.startsWith('low')) {
                return '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "LOW", "reasoning": "unsure"}';
            }
            return 'not json';
        }
    }

    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Miscellaneous Documents', Sort_Order__c = 3)
        };
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id);
    }

    private static StubClassifier useStub() {
        StubClassifier stub = new StubClassifier();
        DNAMS_DocumentClassificationBatch.classifier = stub;
        DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(
            Batch_Size__c = 10,
            Max_Attempts__c = 2,
            Min_Accepted_Confidence__c = 'MODERATE',
            Min_Auto_Accept_Confidence__c = 'FULLY',
            Prompt_Template__c = 'DNAMS_DocumentClassifier_Prompt',
            Narrative_Prompt_Template__c = 'DNAMS_PackageIssueNarrator_Prompt'
        );
        return stub;
    }

    private static DNAMS_Package__c pkg() {
        return [SELECT Id, OwnerId, Health__c, Status__c FROM DNAMS_Package__c LIMIT 1];
    }

    private static Map<String, DNAMS_Package_Element__c> elements() {
        Map<String, DNAMS_Package_Element__c> byName = new Map<String, DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Current_Stage__c, Classification_Status__c, Element_Narrative__c, Classified_As__c, Classification_Confidence__c,
                Extraction_Status__c
            FROM DNAMS_Package_Element__c
        ]) {
            byName.put(element.Name, element);
        }
        return byName;
    }

    private static void attach(String elementName, String title) {
        insert new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = Blob.valueOf(title), FirstPublishLocationId = elements().get(elementName).Id);
    }

    private static AI_Package_Review_Run__c runningRun() {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running', Started_At__c = System.now());
        insert run;
        return run;
    }

    private static AI_Package_Review_Run__c reload(Id runId) {
        return [
            SELECT Status__c, Classification_Processing_Status__c, Overall_Result__c, Reason__c, Trigger_Source__c, Job_Id__c, Error__c, Issue_Summary__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    private static void runClassification(Id runId) {
        Test.startTest();
        new DNAMS_ClassificationStarterQueueable(runId).execute(null);
        Test.stopTest();
    }

    // ------------------------------------------------------------------ steps 2, 3, 5a, 6, 7

    @IsTest
    static void submitStartsRunningRun() {
        useStub();
        Id packageId = pkg().Id;
        update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();

        AI_Package_Review_Run__c run = [SELECT Id, Status__c, Trigger_Source__c, Job_Id__c FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
        Assert.areEqual('Running', run.Status__c);
        Assert.areEqual('Dealer Submit', run.Trigger_Source__c);
        Assert.isNotNull(run.Job_Id__c);
    }

    @IsTest
    static void duplicateRequestIsDiscardedAndRecorded() {
        useStub();
        AI_Package_Review_Run__c active = runningRun();
        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();

        AI_Package_Review_Run__c discarded = [SELECT Status__c, Reason__c, Ended_At__c FROM AI_Package_Review_Run__c WHERE Id != :active.Id];
        Assert.areEqual('Discarded', discarded.Status__c);
        Assert.isTrue(discarded.Reason__c.contains('owned by a queue'), discarded.Reason__c);
        Assert.isNotNull(discarded.Ended_At__c);
    }

    @IsTest
    static void duplicateOnUserOwnedPackageEmailsRmr() {
        useStub();
        Id packageId = pkg().Id;
        update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();
        update new DNAMS_Package__c(Id = packageId, Status__c = 'Returned', OwnerId = UserInfo.getUserId());
        DNAMS_RmrReviewTest.grantRmr(UserInfo.getUserId());
        List<AI_Package_Review_Run__c> earlier = [SELECT Id FROM AI_Package_Review_Run__c];
        for (AI_Package_Review_Run__c run : earlier) {
            run.Status__c = 'Completed';
        }
        update earlier;
        runningRun();

        update new DNAMS_Package__c(Id = packageId, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();

        Assert.areEqual(UserInfo.getUserId(), pkg().OwnerId, 'Resubmit keeps the RMR owner');
        AI_Package_Review_Run__c discarded = [SELECT Status__c, Reason__c, Trigger_Source__c FROM AI_Package_Review_Run__c WHERE Status__c = 'Discarded'];
        Assert.areEqual('Dealer Resubmit', discarded.Trigger_Source__c);
        Assert.isTrue(discarded.Reason__c.contains('emailed the package owner'), discarded.Reason__c);
    }

    @IsTest
    static void submitOnlyFromInitiatedOrReturned() {
        Id packageId = pkg().Id;
        update new DNAMS_Package__c(Id = packageId, Status__c = 'Under Review');
        Database.SaveResult result = Database.update(
            new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted'),
            false
        );
        Assert.areEqual(DNAMS_PackageService.SUBMIT_FROM_MESSAGE, result.getErrors()[0].getMessage());
    }

    // ------------------------------------------------------------------ steps 8-17, 22 (element level)

    @IsTest
    static void elementStagesAndNarrativesShowWhereEachElementIsStuck() {
        StubClassifier stub = useStub();
        attach('Dealer Application', 'good-application');
        attach('Dealer Application', 'wrong-statement');
        attach('Miscellaneous Documents', 'moderate-scan');
        AI_Package_Review_Run__c run = runningRun();

        runClassification(run.Id);

        AI_Package_Review_Run__c done = reload(run.Id);
        Assert.areEqual('Completed', done.Status__c);
        Assert.areEqual('Needs Review', done.Overall_Result__c);
        Assert.areEqual(3, stub.calls);

        Map<String, DNAMS_Package_Element__c> byName = elements();
        DNAMS_Package_Element__c application = byName.get('Dealer Application');
        Assert.areEqual('Failed', application.Classification_Status__c);
        Assert.areEqual('Classification', application.Current_Stage__c);
        Assert.isTrue(application.Element_Narrative__c.contains('Found Bank Statement instead of Dealer Application'), application.Element_Narrative__c);
        Assert.isTrue(application.Classified_As__c.contains('Bank Statement'));
        Assert.isNull(application.Extraction_Status__c, 'Later stages stay empty');

        DNAMS_Package_Element__c chart = byName.get('Org Chart');
        Assert.areEqual('Failed', chart.Classification_Status__c);
        Assert.isTrue(chart.Element_Narrative__c.contains('Required document missing'), chart.Element_Narrative__c);

        DNAMS_Package_Element__c misc = byName.get('Miscellaneous Documents');
        Assert.areEqual('Needs Review', misc.Classification_Status__c);
        Assert.isTrue(misc.Element_Narrative__c.contains('AI unsure'), misc.Element_Narrative__c);
        Assert.areEqual('MODERATE', misc.Classification_Confidence__c);

        Assert.areEqual('Red', pkg().Health__c);
        Assert.areEqual('RMR Pending', pkg().Status__c);
        Assert.isTrue(done.Issue_Summary__c.contains('Org Chart [Failed]'), done.Issue_Summary__c);

        ContentVersion stamped = [SELECT DocumentClassifiedAs__c, Classification_Status__c FROM ContentVersion WHERE Title = 'wrong-statement'];
        Assert.areEqual('Bank Statement', stamped.DocumentClassifiedAs__c);
        Assert.areEqual('Needs Human Review', [SELECT Classification_Status__c FROM ContentVersion WHERE Title = 'moderate-scan'].Classification_Status__c);
    }

    @IsTest
    static void allCorrectPasses() {
        useStub();
        attach('Dealer Application', 'good-application');
        attach('Org Chart', 'good-chart');
        AI_Package_Review_Run__c run = runningRun();

        runClassification(run.Id);

        Assert.areEqual('Passed', reload(run.Id).Overall_Result__c);
        Assert.areEqual('Green', pkg().Health__c);
        Assert.areEqual('Under Review', pkg().Status__c);
        Map<String, DNAMS_Package_Element__c> byName = elements();
        Assert.areEqual('Passed', byName.get('Org Chart').Classification_Status__c);
        Assert.isNull(byName.get('Org Chart').Element_Narrative__c);
        Assert.isNull(byName.get('Miscellaneous Documents').Classification_Status__c, 'Optional element without files stays empty');
    }

    @IsTest
    static void lowConfidenceAndUnreadableFilesFail() {
        StubClassifier stub = useStub();
        attach('Dealer Application', 'low-application');
        attach('Org Chart', 'bad-chart');
        AI_Package_Review_Run__c run = runningRun();

        runClassification(run.Id);

        Map<String, DNAMS_Package_Element__c> byName = elements();
        Assert.isTrue(byName.get('Dealer Application').Element_Narrative__c.contains('Could not identify'));
        Assert.isTrue(byName.get('Org Chart').Element_Narrative__c.contains('could not read'));
        Assert.areEqual(3, stub.calls, 'low once, bad retried twice');
    }

    @IsTest
    static void rerunResetsPreviousResults() {
        useStub();
        attach('Dealer Application', 'good-application');
        AI_Package_Review_Run__c first = runningRun();
        runClassification(first.Id);
        Assert.areEqual('Failed', elements().get('Org Chart').Classification_Status__c);

        update new DNAMS_Package__c(Id = pkg().Id, Status__c = 'Returned'); // the dealer can add files again
        attach('Org Chart', 'good-chart');
        AI_Package_Review_Run__c second = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running');
        insert second;
        new DNAMS_ClassificationStarterQueueable(second.Id).execute(null);
        Assert.areEqual('In Progress', elements().get('Org Chart').Classification_Status__c);
        Assert.isNull(elements().get('Org Chart').Element_Narrative__c, 'Old narrative cleared');
    }

    @IsTest
    static void cancellingRunStopsAndSettlesAsCancelled() {
        useStub();
        attach('Dealer Application', 'good-application');
        AI_Package_Review_Run__c run = runningRun();
        update new AI_Package_Review_Run__c(Id = run.Id, Status__c = 'Cancelling');

        runClassification(run.Id);

        Assert.areEqual('Cancelled', reload(run.Id).Status__c);
        Assert.isNull(elements().get('Dealer Application').Classification_Status__c);
    }

    @IsTest
    static void starterFailureMarksRunFailed() {
        useStub();
        DNAMS_PackageReviewPipelineService.settingsOverride.Batch_Size__c = null; // forces an exception
        attach('Dealer Application', 'good-application');
        AI_Package_Review_Run__c run = runningRun();

        runClassification(run.Id);

        AI_Package_Review_Run__c failed = reload(run.Id);
        Assert.areEqual('Failed', failed.Status__c);
        Assert.isNotNull(failed.Error__c);
    }

    @IsTest
    static void extractionPlaceholderRecordsRequest() {
        AI_Package_Review_Run__c run = runningRun();
        new DNAMS_ExtractionStarterQueueable(run.Id).execute(null);
        Assert.isTrue(reload(run.Id).Reason__c.contains('Extraction requested'));
    }
}