/**
 * @description     Tests the AI package review pipeline: dealer submit starts a run, duplicate requests are discarded,
 *                  classification sets element stages and narratives, a pass publishes Start Extraction, re-runs reset
 *                  results, cancellation and failures settle the run. Every test runs as an inserted System
 *                  Administrator (or RMR user), so the result does not depend on who runs the tests.
 * @author          Sachin Mondal
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details PMD clean-up; tests run as inserted users instead of the running user
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-10-20   Sachin Mondal   Initial version
 * 1.1   2026-11-03   Abhishek Dutta  PMD clean-up; System.runAs with inserted admin / RMR users
 **/
// Exception to guideline: the DNAMS_ prefix is the project's class naming standard for this module
@SuppressWarnings('PMD.ClassNamingConventions')
@IsTest
private class DNAMS_PackageReviewPipelineTest {
    /**
     * @description Answers by file title: good* matches, wrong* is a bank statement, mismatch* claims a match with a type
     *              the element does not accept, moderate* unsure, low* low confidence, bad* malformed.
     **/
    private class StubClassifier implements DNAMS_DocumentClassifier {
        Integer calls = 0;

        /**
         * @description Returns the canned model answer for the file's title.
         * @param promptTemplate    Prompt template name (unused)
         * @param contentDocumentId File being classified
         * @param elementId         Package element the file belongs to
         * @return                  Model response text
         **/
        public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
            calls++;
            String title = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId].Title;
            String expected = [SELECT Name FROM DNAMS_Package_Element__c WHERE Id = :elementId].Name;
            if (title.startsWith('good')) {
                return '```json\n{"matches_expected": true, "document_type": "' + expected + '", "confidence": "FULLY", "reasoning": "clear"}\n```';
            }
            if (title.startsWith('mismatch')) {
                return '{"matches_expected": true, "document_type": "Utility Bill", "confidence": "FULLY", "reasoning": "a bill"}';
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

    /**
     * @description A dealer, three element types (two required) and one Initiated Term Renewal package.
     **/
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

    /**
     * @description Installs the stub classifier, no document type mapping rows and in-memory pipeline settings.
     * @return The stub, so tests can count model calls
     **/
    private static StubClassifier useStub() {
        StubClassifier stub = new StubClassifier();
        DNAMS_DocumentClassificationBatch.classifier = stub;
        DNAMSElementDocumentTypeUtil.rowsOverride = new List<DNAMSElementDocumentType__mdt>(); // no mapping rows: element type name fallback
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

    /**
     * @description The single test package.
     * @return The package with owner, health and status
     **/
    private static DNAMS_Package__c pkg() {
        return [SELECT Id, OwnerId, Health__c, Status__c FROM DNAMS_Package__c LIMIT 1];
    }

    /**
     * @description The test package's elements.
     * @return Elements keyed by name
     **/
    private static Map<String, DNAMS_Package_Element__c> elements() {
        Map<String, DNAMS_Package_Element__c> byName = new Map<String, DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Name, Current_Stage__c, Classification_Status__c, Element_Narrative__c, Classified_As__c, Classification_Confidence__c,
                Extraction_Status__c, AcceptedDocumentTypes__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :pkg().Id
        ]) {
            byName.put(element.Name, element);
        }
        return byName;
    }

    /**
     * @description Uploads a small file to the named element.
     * @param elementName Element name
     * @param title       File title (drives the stub's answer)
     **/
    private static void attach(String elementName, String title) {
        insert new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = Blob.valueOf(title), FirstPublishLocationId = elements().get(elementName).Id);
    }

    /**
     * @description Inserts a Running review run on the test package.
     * @return The run
     **/
    private static AI_Package_Review_Run__c runningRun() {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running', Started_At__c = System.now());
        insert run;
        return run;
    }

    /**
     * @description Re-reads a run.
     * @param runId Run id
     * @return The run with its status fields
     **/
    private static AI_Package_Review_Run__c reload(Id runId) {
        return [
            SELECT Status__c, Classification_Processing_Status__c, Overall_Result__c, Reason__c, Trigger_Source__c, Job_Id__c, Error__c, Issue_Summary__c,
                ExtractionProcessingStatus__c, Ended_At__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
        ];
    }

    /**
     * @description Starts classification for the run and lets the batch finish.
     * @param runId Run id
     **/
    private static void runClassification(Id runId) {
        Test.startTest();
        new DNAMS_ClassificationStarterQueueable(runId).execute(null);
        Test.stopTest();
    }

    // ------------------------------------------------------------------ steps 2, 3, 5a, 6, 7

    /**
     * @description A dealer submit starts a Running run with a job.
     **/
    @IsTest
    static void submitStartsRunningRun() {
        useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id packageId = pkg().Id;
            update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();

            AI_Package_Review_Run__c run = [SELECT Id, Status__c, Trigger_Source__c, Job_Id__c FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
            Assert.areEqual('Running', run.Status__c, 'Submit starts a Running run');
            Assert.areEqual('Dealer Submit', run.Trigger_Source__c, 'Trigger source');
            Assert.isNotNull(run.Job_Id__c, 'The classification job is recorded');
        }
    }

    /**
     * @description A request while a run is active is discarded and the reason recorded.
     **/
    @IsTest
    static void duplicateRequestIsDiscardedAndRecorded() {
        useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            AI_Package_Review_Run__c active = runningRun();
            update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();

            AI_Package_Review_Run__c discarded = [SELECT Status__c, Reason__c, Ended_At__c FROM AI_Package_Review_Run__c WHERE Id != :active.Id];
            Assert.areEqual('Discarded', discarded.Status__c, 'Duplicate request is discarded');
            Assert.isTrue(discarded.Reason__c.contains('owned by a queue'), discarded.Reason__c);
            Assert.isNotNull(discarded.Ended_At__c, 'Discarded run is ended');
        }
    }

    /**
     * @description A duplicate resubmit on a package owned by an RMR user emails that owner and keeps the owner.
     **/
    @IsTest
    static void duplicateOnUserOwnedPackageEmailsRmr() {
        useStub();
        User rmrUser = DNAMS_RmrReviewTest.createRmrUser();
        System.runAs(rmrUser) {
            Id packageId = pkg().Id;
            update new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();
            update new DNAMS_Package__c(Id = packageId, Status__c = 'Returned', OwnerId = rmrUser.Id);
            List<AI_Package_Review_Run__c> earlier = [SELECT Id FROM AI_Package_Review_Run__c WHERE Package__c = :packageId];
            for (AI_Package_Review_Run__c run : earlier) {
                run.Status__c = 'Completed';
            }
            update earlier;
            runningRun();

            update new DNAMS_Package__c(Id = packageId, Status__c = 'Dealer Submitted');
            Test.getEventBus().deliver();

            Assert.areEqual(rmrUser.Id, pkg().OwnerId, 'Resubmit keeps the RMR owner');
            AI_Package_Review_Run__c discarded = [SELECT Status__c, Reason__c, Trigger_Source__c FROM AI_Package_Review_Run__c WHERE Status__c = 'Discarded'];
            Assert.areEqual('Dealer Resubmit', discarded.Trigger_Source__c, 'Trigger source of the resubmit');
            Assert.isTrue(discarded.Reason__c.contains('emailed the package owner'), discarded.Reason__c);
        }
    }

    /**
     * @description Submit is rejected unless the package is Initiated or Returned.
     **/
    @IsTest
    static void submitOnlyFromInitiatedOrReturned() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id packageId = pkg().Id;
            update new DNAMS_Package__c(Id = packageId, Status__c = 'Under Review');
            Database.SaveResult result = Database.update(
                new DNAMS_Package__c(Id = packageId, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted'),
                false
            );
            Assert.areEqual(DNAMS_PackageService.SUBMIT_FROM_MESSAGE, result.getErrors()[0].getMessage(), 'Submit from Under Review is blocked');
        }
    }

    // ------------------------------------------------------------------ steps 8-17, 22 (element level)

    /**
     * @description Wrong, missing and unsure files set each element's stage, status and narrative; the run needs review.
     **/
    @IsTest
    static void elementStagesAndNarrativesShowWhereEachElementIsStuck() {
        StubClassifier stub = useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'good-application');
            attach('Dealer Application', 'wrong-statement');
            attach('Miscellaneous Documents', 'moderate-scan');
            AI_Package_Review_Run__c run = runningRun();

            runClassification(run.Id);

            AI_Package_Review_Run__c done = reload(run.Id);
            Assert.areEqual('Completed', done.Status__c, 'Run with issues completes');
            Assert.areEqual('Needs Review', done.Overall_Result__c, 'Overall result');
            Assert.areEqual(3, stub.calls, 'One model call per file');

            Map<String, DNAMS_Package_Element__c> byName = elements();
            DNAMS_Package_Element__c application = byName.get('Dealer Application');
            Assert.areEqual('Failed', application.Classification_Status__c, 'A wrong file fails the element');
            Assert.areEqual('Classification', application.Current_Stage__c, 'Element is stuck at classification');
            Assert.isTrue(application.Element_Narrative__c.contains('Found Bank Statement instead of Dealer Application'), application.Element_Narrative__c);
            Assert.isTrue(application.Classified_As__c.contains('Bank Statement'), application.Classified_As__c);
            Assert.isNull(application.Extraction_Status__c, 'Later stages stay empty');

            DNAMS_Package_Element__c chart = byName.get('Org Chart');
            Assert.areEqual('Failed', chart.Classification_Status__c, 'Missing required element fails');
            Assert.isTrue(chart.Element_Narrative__c.contains('Required document missing'), chart.Element_Narrative__c);

            DNAMS_Package_Element__c misc = byName.get('Miscellaneous Documents');
            Assert.areEqual('Needs Review', misc.Classification_Status__c, 'Moderate confidence needs review');
            Assert.isTrue(misc.Element_Narrative__c.contains('AI unsure'), misc.Element_Narrative__c);
            Assert.areEqual('MODERATE', misc.Classification_Confidence__c, 'Confidence is stamped');

            Assert.areEqual('Red', pkg().Health__c, 'Package health with issues');
            Assert.areEqual('RMR Pending', pkg().Status__c, 'Package goes to the RMR');
            Assert.isTrue(done.Issue_Summary__c.contains('Org Chart [Failed]'), done.Issue_Summary__c);

            ContentVersion stamped = [SELECT DocumentClassifiedAs__c, Classification_Status__c FROM ContentVersion WHERE Title = 'wrong-statement'];
            Assert.areEqual('Bank Statement', stamped.DocumentClassifiedAs__c, 'File is stamped with the found type');
            Assert.areEqual(
                'Needs Human Review',
                [SELECT Classification_Status__c FROM ContentVersion WHERE Title = 'moderate-scan'].Classification_Status__c,
                'Unsure file needs human review'
            );
        }
    }

    /**
     * @description All required files match: classification completes, the run stays Running and Start Extraction is
     *              published. Test.stopTest() delivers the event and its subscriber queues DNAMSExtractionStarterQueueable,
     *              but a job queued that late does not run in the test, so extraction stays Pending.
     **/
    @IsTest
    static void allCorrectPasses() {
        useStub();
        // Guard: no IDP mapping, so the starter sends nothing should it ever run here (one executeBatch per test method).
        DNAMSIDPActionUtil.actionsOverride = new Map<String, DNAMSIDPWrapper.ActionConfig>();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'good-application');
            attach('Org Chart', 'good-chart');
            AI_Package_Review_Run__c run = runningRun();

            runClassification(run.Id);

            AI_Package_Review_Run__c passed = reload(run.Id);
            Assert.areEqual('Running', passed.Status__c, 'A passing run stays Running for extraction');
            Assert.areEqual('Completed', passed.Classification_Processing_Status__c, 'Classification stage is done');
            Assert.areEqual('Pending', passed.ExtractionProcessingStatus__c, 'Extraction waits for the queued starter');
            Assert.areEqual(
                1,
                [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DNAMSExtractionStarterQueueable' AND Status = 'Queued'],
                'The delivered Start Extraction event queued the extraction starter'
            );
            Assert.isNull(passed.Ended_At__c, 'The run has not ended');
            List<DNAMSIDPEvent__e> events = DNAMS_PackageReviewPipelineService.publishedEvents;
            Assert.areEqual(1, events.size(), 'One Start Extraction event');
            Assert.areEqual(DNAMSPipelineConstants.EVENT_START_EXTRACTION, events[0].EventType__c, 'Event type');
            Assert.areEqual(String.valueOf(run.Id), events[0].ReviewRunId__c, 'Event carries the run');
            Assert.areEqual('Green', pkg().Health__c, 'Package health unchanged on pass');
            Assert.areEqual('Under Review', pkg().Status__c, 'Package status unchanged on pass');
            Map<String, DNAMS_Package_Element__c> byName = elements();
            Assert.areEqual('Passed', byName.get('Org Chart').Classification_Status__c, 'Org Chart passed');
            Assert.isNull(byName.get('Org Chart').Element_Narrative__c, 'No narrative for a pass');
            Assert.isNull(byName.get('Miscellaneous Documents').Classification_Status__c, 'Optional element without files stays empty');
            List<AIReviewStageResult__c> classified = [
                SELECT Outcome__c, ProcessingStatus__c, DocumentType__c, Confidence__c, RawStageResponseJSON__c
                FROM AIReviewStageResult__c
                WHERE ReviewRun__c = :run.Id AND Stage__c = :DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION
                WITH SYSTEM_MODE
            ];
            Assert.areEqual(2, classified.size(), 'One Classification row per classified file');
            for (AIReviewStageResult__c row : classified) {
                Assert.areEqual('Match', row.Outcome__c, 'Outcome recorded: ' + row.DocumentType__c);
                Assert.areEqual('Completed', row.ProcessingStatus__c, 'Row completed: ' + row.DocumentType__c);
                Assert.isNotNull(row.RawStageResponseJSON__c, 'Raw AI response kept: ' + row.DocumentType__c);
            }
        }
    }

    /**
     * @description Accepted types come from the mapping rows (or the element type definition) and a type outside them fails.
     **/
    @IsTest
    static void acceptedTypesComeFromMappingAndAreChecked() {
        StubClassifier stub = useStub();
        DNAMSElementDocumentTypeUtil.rowsOverride = new List<DNAMSElementDocumentType__mdt>{
            new DNAMSElementDocumentType__mdt(
                ElementType__c = 'Dealer Application', DocumentType__c = 'Dealer Application', IdentifyingInstructions__c = 'The application form.',
                SortOrder__c = 1, IsActive__c = true
            ),
            new DNAMSElementDocumentType__mdt(
                ElementType__c = 'Dealer Application', DocumentType__c = 'Dealer Agreement', IdentifyingInstructions__c = 'The signed\nagreement.',
                SortOrder__c = 2, IsActive__c = true
            )
        };
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            update new DNAMS_Element_Type__c(
                Id = [SELECT Id FROM DNAMS_Element_Type__c WHERE Name = 'Org Chart' LIMIT 1].Id,
                Identifying_Definition__c = 'A chart of roles.'
            );
            attach('Dealer Application', 'mismatch-bill');
            attach('Org Chart', 'good-chart');
            AI_Package_Review_Run__c run = runningRun();

            runClassification(run.Id);

            Map<String, DNAMS_Package_Element__c> byName = elements();
            DNAMS_Package_Element__c application = byName.get('Dealer Application');
            Assert.areEqual(
                '- Dealer Application: The application form.\n- Dealer Agreement: The signed agreement.',
                application.AcceptedDocumentTypes__c,
                'Prompt input lists the mapped document types'
            );
            Assert.areEqual('- Org Chart: A chart of roles.', byName.get('Org Chart').AcceptedDocumentTypes__c, 'Fallback to the element type definition');
            Assert.isNull(byName.get('Miscellaneous Documents').AcceptedDocumentTypes__c, 'Element without files gets no prompt input');
            Assert.areEqual('Failed', application.Classification_Status__c, 'A type outside the accepted list fails even if the AI claims a match');
            Assert.isTrue(
                application.Element_Narrative__c.contains('Found Utility Bill instead of Dealer Application or Dealer Agreement'),
                application.Element_Narrative__c
            );
            Assert.areEqual('Passed', byName.get('Org Chart').Classification_Status__c, 'Fallback accepts the element type name');
            Assert.areEqual(2, stub.calls, 'One call per file');
            Assert.areEqual('Completed', reload(run.Id).Status__c, 'Issues complete the run as before');
        }
    }

    /**
     * @description Low confidence and unreadable answers fail the element; malformed answers are retried.
     **/
    @IsTest
    static void lowConfidenceAndUnreadableFilesFail() {
        StubClassifier stub = useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'low-application');
            attach('Org Chart', 'bad-chart');
            AI_Package_Review_Run__c run = runningRun();

            runClassification(run.Id);

            Map<String, DNAMS_Package_Element__c> byName = elements();
            String applicationNarrative = byName.get('Dealer Application').Element_Narrative__c;
            String chartNarrative = byName.get('Org Chart').Element_Narrative__c;
            Assert.isTrue(applicationNarrative.contains('Could not identify'), applicationNarrative);
            Assert.isTrue(chartNarrative.contains('could not read'), chartNarrative);
            Assert.areEqual(3, stub.calls, 'low once, bad retried twice');
        }
    }

    /**
     * @description A new run resets the previous run's element results.
     **/
    @IsTest
    static void rerunResetsPreviousResults() {
        useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'good-application');
            AI_Package_Review_Run__c first = runningRun();
            runClassification(first.Id);
            Assert.areEqual('Failed', elements().get('Org Chart').Classification_Status__c, 'First run fails the missing Org Chart');

            update new DNAMS_Package__c(Id = pkg().Id, Status__c = 'Returned'); // the dealer can add files again
            attach('Org Chart', 'good-chart');
            AI_Package_Review_Run__c second = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running');
            insert second;
            new DNAMS_ClassificationStarterQueueable(second.Id).execute(null);
            Assert.areEqual('In Progress', elements().get('Org Chart').Classification_Status__c, 'Second run restarts classification');
            Assert.isNull(elements().get('Org Chart').Element_Narrative__c, 'Old narrative cleared');
        }
    }

    /**
     * @description A Cancelling run stops before classifying and settles as Cancelled.
     **/
    @IsTest
    static void cancellingRunStopsAndSettlesAsCancelled() {
        useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'good-application');
            AI_Package_Review_Run__c run = runningRun();
            update new AI_Package_Review_Run__c(Id = run.Id, Status__c = 'Cancelling');

            runClassification(run.Id);

            Assert.areEqual('Cancelled', reload(run.Id).Status__c, 'Cancelling settles as Cancelled');
            Assert.isNull(elements().get('Dealer Application').Classification_Status__c, 'No element was classified');
        }
    }

    /**
     * @description An exception in the starter fails the run and records the error.
     **/
    @IsTest
    static void starterFailureMarksRunFailed() {
        useStub();
        DNAMS_PackageReviewPipelineService.settingsOverride.Batch_Size__c = null; // forces an exception
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach('Dealer Application', 'good-application');
            AI_Package_Review_Run__c run = runningRun();

            runClassification(run.Id);

            AI_Package_Review_Run__c failed = reload(run.Id);
            Assert.areEqual('Failed', failed.Status__c, 'Run failed');
            Assert.isNotNull(failed.Error__c, 'Error recorded');
        }
    }

    /**
     * @description failRun marks only the given stage as Failed.
     **/
    @IsTest
    static void failRunRecordsTheGivenStage() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            AI_Package_Review_Run__c run = runningRun();

            Test.startTest();
            DNAMS_PackageReviewPipelineService.failRun(
                run.Id,
                AI_Package_Review_Run__c.ExtractionProcessingStatus__c,
                new DNAMS_PackageReviewPipelineService.PipelineException('extraction crashed')
            );
            Test.stopTest();

            AI_Package_Review_Run__c failed = reload(run.Id);
            Assert.areEqual('Failed', failed.Status__c, 'Run failed');
            Assert.areEqual('Failed', failed.ExtractionProcessingStatus__c, 'Extraction stage failed');
            Assert.areNotEqual('Failed', failed.Classification_Processing_Status__c, 'Classification stage untouched');
            Assert.isTrue(failed.Error__c.contains('extraction crashed'), failed.Error__c);
        }
    }
}
