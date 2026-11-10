/**
 * @description     Tests "Re-run changes only" for pre-flight and classification: unchanged files reuse the baseline's
 *                  Classification row without a model call, new versions / new files / unfinished rows are classified
 *                  again, removed files get no row, element results equal a full run, ContentVersion stamps are
 *                  re-applied and the Classification line is appended to ChangeSummary__c. An All run is unchanged.
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
private class DNAMSRerunClassificationTest {
    private static final String DA = 'Dealer Application';
    private static final String OC = 'Org Chart';
    private static final String MISC = 'Miscellaneous Documents';
    private static final String CLASSIFICATION = 'Classification';

    /**
     * @description Answers by file title (good* matches, wrong* is a bank statement, moderate* unsure) and records
     *              every file it was asked about.
     **/
    private class StubClassifier implements DNAMS_DocumentClassifier {
        Integer calls = 0;
        Set<Id> documentIds = new Set<Id>();

        /**
         * @description Returns the canned model answer for the file's title.
         * @param promptTemplate    Prompt template name (unused)
         * @param contentDocumentId File being classified
         * @param elementId         Package element the file belongs to
         * @return                  Model response text
         **/
        public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
            calls++;
            documentIds.add(contentDocumentId);
            String title = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId].Title;
            String expected = [SELECT Name FROM DNAMS_Package_Element__c WHERE Id = :elementId].Name;
            if (title.startsWith('wrong')) {
                return '{"matches_expected": false, "document_type": "Bank Statement", "confidence": "FULLY", "reasoning": "a statement"}';
            }
            if (title.startsWith('moderate')) {
                return '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "MODERATE", "reasoning": "probably"}';
            }
            return '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "FULLY", "reasoning": "clear"}';
        }
    }

    /**
     * @description A dealer, three element types (two required) and one Initiated Term Renewal package.
     **/
    @TestSetup
    static void setup() {
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        List<DNAMS_Element_Type__c> types = new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = DA, Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = OC, Sort_Order__c = 2, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = MISC, Sort_Order__c = 3)
        };
        insert types;
        DNAMSPipelineTestHelper.mapElementTypes('Term Renewal', types);
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id);
    }

    // ------------------------------------------------------------------ helpers

    /**
     * @description Installs the stub classifier, no document type mapping rows and in-memory pipeline settings.
     * @return The stub, so tests can count model calls
     **/
    private static StubClassifier useStub() {
        StubClassifier stub = new StubClassifier();
        DNAMS_DocumentClassificationBatch.classifier = stub;
        DNAMSElementDocumentTypeUtil.rowsOverride = new List<DNAMSElementDocumentType__mdt>();
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

    private static Id packageId() {
        return [SELECT Id FROM DNAMS_Package__c LIMIT 1].Id;
    }

    private static List<DNAMS_Package_Element__c> elements() {
        return [
            SELECT Id, Name, Element_Type__r.Name, Classification_Status__c, Classified_As__c, Classification_Confidence__c,
                Classification_Reasoning__c, Element_Narrative__c
            FROM DNAMS_Package_Element__c
            WHERE Package__c = :packageId()
            ORDER BY Sort_Order__c
        ];
    }

    private static Id elementId(String name) {
        return [SELECT Id FROM DNAMS_Package_Element__c WHERE Name = :name LIMIT 1].Id;
    }

    private static Id attach(String elementName, String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf(title),
            FirstPublishLocationId = elementId(elementName)
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    private static AI_Package_Review_Run__c newRun(String mode, Id baselineRunId) {
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(
            Package__c = packageId(),
            Status__c = 'Running',
            Started_At__c = System.now(),
            RerunMode__c = mode,
            BaselineRun__c = baselineRunId,
            ChangeSummary__c = baselineRunId == null ? null : 'Compared with baseline.'
        );
        insert run;
        return run;
    }

    /**
     * @description Classifies every element of the package for the run in this transaction (batch execute called
     *              directly), then marks the run Completed: a baseline as a real run leaves it.
     * @param run Running run
     **/
    private static void classifyNow(AI_Package_Review_Run__c run) {
        new DNAMS_DocumentClassificationBatch(run.Id, run.Package__c).execute(null, elements());
        update new AI_Package_Review_Run__c(Id = run.Id, Status__c = 'Completed');
    }

    private static Map<String, AIReviewStageResult__c> rowsByTitle(Id runId) {
        Map<String, AIReviewStageResult__c> byTitle = new Map<String, AIReviewStageResult__c>();
        for (AIReviewStageResult__c row : [
            SELECT Id, DocumentTitle__c, ReusedFromResult__c, Outcome__c, DocumentType__c, ContentVersionId__c, ProcessingStatus__c
            FROM AIReviewStageResult__c
            WHERE ReviewRun__c = :runId AND Stage__c = :CLASSIFICATION
        ]) {
            byTitle.put(row.DocumentTitle__c, row);
        }
        return byTitle;
    }

    private static Map<Id, String> elementSnapshot() {
        Map<Id, String> snapshot = new Map<Id, String>();
        for (DNAMS_Package_Element__c element : elements()) {
            snapshot.put(
                element.Id,
                String.join(
                    new List<String>{
                        element.Classification_Status__c, element.Classified_As__c, element.Classification_Confidence__c,
                        element.Classification_Reasoning__c, element.Element_Narrative__c
                    },
                    ' | '
                )
            );
        }
        return snapshot;
    }

    // ------------------------------------------------------------------ tests

    /**
     * @description Unchanged files are reused without a model call (including a failing Wrong answer); a new version,
     *              a new file and a baseline Error row are classified again; a removed file gets no row; the reused
     *              file's stamp is re-applied; element results equal a full run; the change summary line is appended.
     **/
    @IsTest
    static void changesOnlyReusesUnchangedFilesAndRerunsChangedOnes() {
        StubClassifier stub = useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id applicationDoc = attach(DA, 'good-application');
            Id statementDoc = attach(DA, 'wrong-statement');
            Id chartDoc = attach(OC, 'good-chart');
            Id miscDoc = attach(MISC, 'good-misc');
            Id removedDoc = attach(MISC, 'moderate-scan');
            AI_Package_Review_Run__c baseline = newRun(DNAMSPipelineConstants.RERUN_MODE_ALL, null);
            classifyNow(baseline);
            Map<String, AIReviewStageResult__c> baselineRows = rowsByTitle(baseline.Id);
            Assert.areEqual(5, baselineRows.size(), 'Baseline has one row per file');
            // good-misc did not finish in the baseline
            update new AIReviewStageResult__c(Id = baselineRows.get('good-misc.pdf').Id, ProcessingStatus__c = 'Error', Outcome__c = 'Error');

            // Changes: new version of the chart, a new misc file, the unsure scan removed, one stamp lost
            insert new ContentVersion(ContentDocumentId = chartDoc, Title = 'good-chart', PathOnClient = 'good-chart.pdf', VersionData = Blob.valueOf('v2'));
            Id addedDoc = attach(MISC, 'good-added');
            delete [SELECT Id FROM ContentDocument WHERE Id = :removedDoc];
            ContentVersion applicationVersion = [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :applicationDoc AND IsLatest = TRUE];
            update new ContentVersion(Id = applicationVersion.Id, DocumentClassifiedAs__c = null, Classification_Status__c = null);

            AI_Package_Review_Run__c changesOnly = newRun(DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY, baseline.Id);
            stub.calls = 0;
            stub.documentIds.clear();
            Test.startTest();
            new DNAMS_ClassificationStarterQueueable(changesOnly.Id).execute(null);
            Test.stopTest();

            Assert.areEqual(3, stub.calls, 'Only the new version, the new file and the unfinished file are classified');
            Assert.areEqual(new Set<Id>{ chartDoc, addedDoc, miscDoc }, stub.documentIds, 'Model calls only for changed files');
            Assert.isFalse(stub.documentIds.contains(applicationDoc) || stub.documentIds.contains(statementDoc), 'Unchanged files are not sent to the model');

            Map<String, AIReviewStageResult__c> rows = rowsByTitle(changesOnly.Id);
            Assert.areEqual(5, rows.size(), 'One row per current file; the removed file has none');
            Assert.isFalse(rows.containsKey('moderate-scan.pdf'), 'Removed file gets no row');
            Assert.areEqual(baselineRows.get('good-application.pdf').Id, rows.get('good-application.pdf').ReusedFromResult__c, 'Reused row points at its origin');
            Assert.areEqual(baselineRows.get('wrong-statement.pdf').Id, rows.get('wrong-statement.pdf').ReusedFromResult__c, 'A failing answer is reused too');
            Assert.areEqual('Wrong', rows.get('wrong-statement.pdf').Outcome__c, 'Reused outcome');
            Assert.isNull(rows.get('good-chart.pdf').ReusedFromResult__c, 'New version is classified again');
            Assert.isNull(rows.get('good-added.pdf').ReusedFromResult__c, 'New file is classified');
            Assert.isNull(rows.get('good-misc.pdf').ReusedFromResult__c, 'Unfinished baseline row is classified again');
            Assert.areEqual('Completed', rows.get('good-misc.pdf').ProcessingStatus__c, 'Re-run row completes');

            ContentVersion restamped = [SELECT DocumentClassifiedAs__c, Classification_Status__c FROM ContentVersion WHERE Id = :applicationVersion.Id];
            Assert.areEqual(DA, restamped.DocumentClassifiedAs__c, 'Reused file stamp is re-applied');
            Assert.areEqual('Classified', restamped.Classification_Status__c, 'Reused file status stamp');

            String summary = [SELECT ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Id = :changesOnly.Id].ChangeSummary__c;
            Assert.isTrue(summary.startsWith('Compared with baseline.\nClassification: 2 reused, 3 re-run ('), summary);
            Assert.isTrue(summary.contains('Org Chart / good-chart.pdf: new version'), summary);
            Assert.isTrue(summary.contains('Miscellaneous Documents / good-added.pdf: new file'), summary);
            Assert.isTrue(summary.contains('good-misc.pdf: did not finish'), summary);
            Assert.isTrue(summary.contains('moderate-scan.pdf: removed'), summary);

            // A full run over the same files gives the same element results
            Map<Id, String> changesOnlyResult = elementSnapshot();
            classifyNow(newRun(DNAMSPipelineConstants.RERUN_MODE_ALL, null));
            Assert.areEqual(elementSnapshot(), changesOnlyResult, 'Element results equal a full run');
            Assert.areEqual(3 + 5, stub.calls, 'The full run classifies every file');
        }
    }

    /**
     * @description An All run classifies every file even when an earlier run exists, writes no reused rows and leaves
     *              the change summary alone.
     **/
    @IsTest
    static void allRunClassifiesEverything() {
        StubClassifier stub = useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            attach(DA, 'good-application');
            attach(OC, 'good-chart');
            attach(MISC, 'wrong-statement'); // an issue ends the run at classification (no extraction batch in the test)
            AI_Package_Review_Run__c baseline = newRun(DNAMSPipelineConstants.RERUN_MODE_ALL, null);
            classifyNow(baseline);
            AI_Package_Review_Run__c allRun = newRun(DNAMSPipelineConstants.RERUN_MODE_ALL, null);
            stub.calls = 0;
            Test.startTest();
            new DNAMS_ClassificationStarterQueueable(allRun.Id).execute(null);
            Test.stopTest();

            Assert.areEqual(3, stub.calls, 'Every file is classified');
            for (AIReviewStageResult__c row : rowsByTitle(allRun.Id).values()) {
                Assert.isNull(row.ReusedFromResult__c, 'Nothing is reused in an All run');
            }
            Assert.isNull([SELECT ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Id = :allRun.Id].ChangeSummary__c, 'No summary line');
        }
    }

    /**
     * @description With every file removed, a Changes Only run classifies nothing and still records the removal.
     **/
    @IsTest
    static void changesOnlyWithAllFilesRemovedRecordsRemoval() {
        StubClassifier stub = useStub();
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            Id chartDoc = attach(OC, 'good-chart');
            AI_Package_Review_Run__c baseline = newRun(DNAMSPipelineConstants.RERUN_MODE_ALL, null);
            classifyNow(baseline);
            delete [SELECT Id FROM ContentDocument WHERE Id = :chartDoc];
            AI_Package_Review_Run__c changesOnly = newRun(DNAMSPipelineConstants.RERUN_MODE_CHANGES_ONLY, baseline.Id);
            stub.calls = 0;
            Test.startTest();
            new DNAMS_ClassificationStarterQueueable(changesOnly.Id).execute(null);
            Test.stopTest();

            Assert.areEqual(0, stub.calls, 'No file to classify');
            Assert.isTrue(rowsByTitle(changesOnly.Id).isEmpty(), 'No rows');
            String summary = [SELECT ChangeSummary__c FROM AI_Package_Review_Run__c WHERE Id = :changesOnly.Id].ChangeSummary__c;
            Assert.isTrue(summary.contains('Classification: 0 reused, 0 re-run (Org Chart / good-chart.pdf: removed)'), summary);
        }
    }

    /**
     * @description A reused row applies the stored answer with the current accepted types; without a readable stored
     *              answer it keeps the baseline's result.
     **/
    @IsTest
    static void reuseResultReappliesStoredAnswerOrKeepsBaseline() {
        useStub();
        DNAMS_DocumentClassificationBatch.FileResult fresh = new DNAMS_DocumentClassificationBatch.FileResult();
        fresh.acceptedNames = new Set<String>{ 'utility bill' };
        AIReviewStageResult__c answered = new AIReviewStageResult__c(
            Outcome__c = 'Wrong',
            DocumentType__c = 'Utility Bill',
            Confidence__c = 'FULLY',
            RawStageResponseJSON__c = '{"document_type": "Utility Bill", "confidence": "FULLY", "reasoning": "a bill"}'
        );
        Test.startTest();
        DNAMS_DocumentClassificationBatch.reuseResult(fresh, answered);
        DNAMS_DocumentClassificationBatch.FileResult kept = new DNAMS_DocumentClassificationBatch.FileResult();
        DNAMS_DocumentClassificationBatch.reuseResult(
            kept,
            new AIReviewStageResult__c(Outcome__c = 'Unsure', DocumentType__c = 'Org Chart', Confidence__c = 'MODERATE', Reasoning__c = 'maybe')
        );
        Test.stopTest();

        Assert.areEqual('Match', fresh.outcome, 'Stored answer re-applied against the current accepted types');
        Assert.areEqual(answered, fresh.reusedFrom, 'Origin row recorded');
        Assert.areEqual('Unsure', kept.outcome, 'Baseline outcome kept without a stored answer');
        Assert.areEqual('MODERATE', kept.confidence, 'Baseline confidence kept');
        Assert.areEqual('maybe', kept.reasoning, 'Baseline reasoning kept');
    }
}
