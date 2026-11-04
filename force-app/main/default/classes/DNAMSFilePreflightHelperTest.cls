/**
 * @description     Tests DNAMSFilePreflightHelper and its use in DNAMS_ClassificationStarterQueueable: only allowed file
 *                  types within the size limit continue; anything else stops the run before any AI step.
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
private class DNAMSFilePreflightHelperTest {
    private static final String DEALER_APPLICATION = 'Dealer Application';

    /**
     * @description Reloads the run with the fields the gate sets.
     * @param runId Review run id
     * @return      The run
     **/
    private static AI_Package_Review_Run__c reloadRun(Id runId) {
        return [
            SELECT Id, Package__c, Status__c, Classification_Processing_Status__c, Overall_Result__c, Issue_Summary__c, Ended_At__c
            FROM AI_Package_Review_Run__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Adds a Word file to an element of the fixture package.
     * @param fixture Pipeline fixture
     **/
    private static void attachWordFile(DNAMSPipelineTestHelper.PipelineFixture fixture) {
        insert as system new ContentVersion(
            Title = 'notes',
            PathOnClient = 'notes.docx',
            VersionData = Blob.valueOf('not a pdf'),
            FirstPublishLocationId = fixture.elementIdByType.get(DEALER_APPLICATION)
        );
    }

    /**
     * @description Error logs written for the run.
     * @param runId Review run id
     * @return      Logs
     **/
    private static List<AIReviewErrorLog__c> logsFor(Id runId) {
        return [
            SELECT ErrorType__c, Stage__c, DocumentTitle__c, Message__c, PackageElement__c
            FROM AIReviewErrorLog__c
            WHERE ReviewRun__c = :runId
            WITH SYSTEM_MODE
        ];
    }

    /**
     * @description All files are small PDFs: the gate passes and changes nothing.
     **/
    @IsTest
    static void testPassesPreflightAllSmallPdfsReturnsTrue() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMS_PackageReviewPipelineService.settingsOverride = DNAMSPipelineTestHelper.getPipelineSettings();

            Test.startTest();
            Boolean passed = DNAMSFilePreflightHelper.passesPreflight(reloadRun(fixture.runId));
            Test.stopTest();

            Assert.isTrue(passed, 'Small PDFs pass the gate');
            Assert.areEqual('Running', reloadRun(fixture.runId).Status__c, 'Run keeps running');
            Assert.areEqual(0, logsFor(fixture.runId).size(), 'No error logs');
        }
    }

    /**
     * @description A Word file stops the run: log, failed element with narrative, Red package, Needs Review run.
     **/
    @IsTest
    static void testPassesPreflightWordFileStopsRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMS_PackageReviewPipelineService.settingsOverride = DNAMSPipelineTestHelper.getPipelineSettings();
            attachWordFile(fixture);

            Test.startTest();
            Boolean passed = DNAMSFilePreflightHelper.passesPreflight(reloadRun(fixture.runId));
            Test.stopTest();

            Assert.isFalse(passed, 'A Word file fails the gate');
            List<AIReviewErrorLog__c> logs = logsFor(fixture.runId);
            Assert.areEqual(1, logs.size(), 'One log for the one bad file');
            Assert.areEqual(DNAMSPipelineConstants.ERROR_INVALID_FILE_TYPE, logs[0].ErrorType__c, 'Invalid File Type');
            Assert.areEqual(DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION, logs[0].Stage__c, 'Logged at the start of the pipeline');
            Assert.areEqual('notes.docx', logs[0].DocumentTitle__c, 'Names the file');
            DNAMS_Package_Element__c element = [
                SELECT Classification_Status__c, Element_Narrative__c FROM DNAMS_Package_Element__c
                WHERE Id = :fixture.elementIdByType.get(DEALER_APPLICATION) WITH SYSTEM_MODE
            ];
            Assert.areEqual('Failed', element.Classification_Status__c, 'Element with the bad file fails');
            Assert.isTrue(element.Element_Narrative__c.contains('notes.docx'), 'Narrative names the file: ' + element.Element_Narrative__c);
            AI_Package_Review_Run__c run = reloadRun(fixture.runId);
            Assert.areEqual('Completed', run.Status__c, 'Run stops');
            Assert.areEqual('Needs Review', run.Overall_Result__c, 'Run needs review');
            Assert.areEqual('Failed', run.Classification_Processing_Status__c, 'Classification never ran');
            Assert.isTrue(run.Issue_Summary__c.contains('Invalid File Type'), 'Summary lists the problem: ' + run.Issue_Summary__c);
            DNAMS_Package__c pkg = [SELECT Health__c, Status__c, AI_Narrative__c FROM DNAMS_Package__c WHERE Id = :fixture.packageId WITH SYSTEM_MODE];
            Assert.areEqual('Red', pkg.Health__c, 'Package health Red');
            Assert.areEqual('RMR Pending', pkg.Status__c, 'Package goes to the RMR');
            Assert.isNotNull(pkg.AI_Narrative__c, 'Narrative written for the RMR');
        }
    }

    /**
     * @description Files above the size limit stop the run with one File Too Large log per file.
     **/
    @IsTest
    static void testPassesPreflightOversizedFilesStopRun() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMS_Pipeline_Setting__mdt setting = DNAMSPipelineTestHelper.getPipelineSettings();
            setting.MaxFileSizeMB__c = 0.00001; // about 10 bytes: every fixture file is larger
            DNAMS_PackageReviewPipelineService.settingsOverride = setting;

            Test.startTest();
            Boolean passed = DNAMSFilePreflightHelper.passesPreflight(reloadRun(fixture.runId));
            Test.stopTest();

            Assert.isFalse(passed, 'Oversized files fail the gate');
            List<AIReviewErrorLog__c> logs = logsFor(fixture.runId);
            Assert.areEqual(fixture.versionIdByDocumentType.size(), logs.size(), 'One log per oversized file');
            for (AIReviewErrorLog__c log : logs) {
                Assert.areEqual(DNAMSPipelineConstants.ERROR_FILE_TOO_LARGE, log.ErrorType__c, 'File Too Large: ' + log.DocumentTitle__c);
                Assert.isTrue(log.Message__c.contains('the limit is'), 'Reason states the limit: ' + log.Message__c);
            }
        }
    }

    /**
     * @description The classification starter runs the gate first: a Word file means no classification batch starts.
     **/
    @IsTest
    static void testClassificationStarterWordFileNoAiStep() {
        System.runAs(DNAMSPipelineTestHelper.getAdminUser()) {
            DNAMSPipelineTestHelper.PipelineFixture fixture = DNAMSPipelineTestHelper.createExtractionFixture();
            DNAMS_PackageReviewPipelineService.settingsOverride = DNAMSPipelineTestHelper.getPipelineSettings();
            attachWordFile(fixture);

            Test.startTest();
            new DNAMS_ClassificationStarterQueueable(fixture.runId).execute(null);
            Test.stopTest();

            Integer batches = [
                SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DNAMS_DocumentClassificationBatch' AND JobType = 'BatchApex'
            ];
            Assert.areEqual(0, batches, 'No classification (AI) batch started');
            Assert.areEqual('Needs Review', reloadRun(fixture.runId).Overall_Result__c, 'Run stopped at the gate');
        }
    }
}
