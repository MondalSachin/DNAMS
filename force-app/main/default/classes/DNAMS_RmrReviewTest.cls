@IsTest
public class DNAMS_RmrReviewTest {
    /** "good*" -> FULLY match; anything else -> FULLY wrong type. */
    private class StubClassifier implements DNAMS_DocumentClassifier {
        public String classify(String promptTemplate, Id contentDocumentId, Id elementId) {
            String title = [SELECT Title FROM ContentDocument WHERE Id = :contentDocumentId].Title;
            String expected = [SELECT Name FROM DNAMS_Package_Element__c WHERE Id = :elementId].Name;
            return title.startsWith('good')
                ? '{"matches_expected": true, "document_type": "' + expected + '", "confidence": "FULLY", "reasoning": "clear"}'
                : '{"matches_expected": false, "document_type": "Bank Statement", "confidence": "FULLY", "reasoning": "a statement"}';
        }
    }

    private class StubWriter implements DNAMS_NarrativeWriter {
        Boolean fail = false;

        public String write(String promptTemplate, Id runId) {
            if (fail) {
                throw new DNAMS_PackageReviewPipelineService.PipelineException('model down');
            }
            return 'Org Chart: a bank statement was uploaded instead of the ownership chart.';
        }
    }

    public static void grantRmr(Id userId) {
        Id permissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DNAMS_RMR'].Id;
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSetId = :permissionSetId] == 0) {
            insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId);
        }
    }

    @TestSetup
    static void setup() {
        grantRmr(UserInfo.getUserId());
        Account dealer = new Account(Name = 'Dealer', AccountNumber = 'TCE00087');
        insert dealer;
        Contact principal = new Contact(LastName = 'Principal', AccountId = dealer.Id, Email = 'principal@example.com');
        insert principal;
        insert new List<DNAMS_Element_Type__c>{
            new DNAMS_Element_Type__c(Name = 'Dealer Application', Sort_Order__c = 1, Is_Required__c = true),
            new DNAMS_Element_Type__c(Name = 'Org Chart', Sort_Order__c = 2, Is_Required__c = true)
        };
        insert new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id, Primary_Contact__c = principal.Id);
    }

    private static StubWriter useStubs() {
        DNAMS_DocumentClassificationBatch.classifier = new StubClassifier();
        StubWriter writer = new StubWriter();
        DNAMS_PackageNarrativeQueueable.writer = writer;
        DNAMS_PackageReviewPipelineService.settingsOverride = new DNAMS_Pipeline_Setting__mdt(
            Batch_Size__c = 10,
            Max_Attempts__c = 1,
            Min_Accepted_Confidence__c = 'MODERATE',
            Min_Auto_Accept_Confidence__c = 'FULLY',
            Prompt_Template__c = 'DNAMS_DocumentClassifier_Prompt',
            Narrative_Prompt_Template__c = 'DNAMS_PackageIssueNarrator_Prompt'
        );
        return writer;
    }

    private static DNAMS_Package__c pkg() {
        return [SELECT Id, Status__c, Health__c, AI_Narrative__c, Upload_Link_Sent_To__c FROM DNAMS_Package__c LIMIT 1];
    }

    private static void attach(String elementName, String title) {
        Id elementId = [SELECT Id FROM DNAMS_Package_Element__c WHERE Name = :elementName].Id;
        insert new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = Blob.valueOf(title), FirstPublishLocationId = elementId);
    }

    /** Submits (override), retires the event's run, then classifies with the stub; returns the run. */
    private static AI_Package_Review_Run__c submitAndClassify() {
        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();
        List<AI_Package_Review_Run__c> fromEvent = [SELECT Id FROM AI_Package_Review_Run__c];
        for (AI_Package_Review_Run__c eventRun : fromEvent) {
            eventRun.Status__c = 'Completed';
        }
        update fromEvent;
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running', Started_At__c = System.now());
        insert run;
        Test.startTest();
        new DNAMS_ClassificationStarterQueueable(run.Id).execute(null);
        Test.stopTest();
        return run;
    }

    private static AI_Package_Review_Run__c reload(Id runId) {
        return [SELECT Status__c, Overall_Result__c, Reason__c, Error__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
    }

    private static String cancelViaFlow(Id packageId) {
        DNAMS_CancelReviewAction.Request request = new DNAMS_CancelReviewAction.Request();
        request.packageId = packageId;
        return DNAMS_CancelReviewAction.run(new List<DNAMS_CancelReviewAction.Request>{ request })[0].message;
    }

    private static String rerunViaFlow(Id packageId) {
        DNAMS_RerunReviewAction.Request request = new DNAMS_RerunReviewAction.Request();
        request.packageId = packageId;
        return DNAMS_RerunReviewAction.run(new List<DNAMS_RerunReviewAction.Request>{ request })[0].message;
    }

    private static String returnViaFlow(Id packageId, String email) {
        DNAMS_ReturnToDealerAction.Request request = new DNAMS_ReturnToDealerAction.Request();
        request.packageId = packageId;
        request.recipientEmail = email;
        return DNAMS_ReturnToDealerAction.run(new List<DNAMS_ReturnToDealerAction.Request>{ request })[0].message;
    }

    // ------------------------------------------------------------------ 1b cancel / re-run

    @IsTest
    static void cancelRunningRunMarksCancelling() {
        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Running');
        insert run;

        String message = cancelViaFlow(pkg().Id);

        Assert.isTrue(message.contains('being cancelled'), message);
        Assert.areEqual('Cancelling', reload(run.Id).Status__c);
        Assert.isTrue(cancelViaFlow(pkg().Id).contains('no review in progress'));
    }

    @IsTest
    static void rerunOnlyAfterSubmitAndPublishesRequest() {
        useStubs();
        String blocked = rerunViaFlow(pkg().Id);
        Assert.isTrue(blocked.contains('Re-run is not available') && blocked.contains('Initiated'), blocked);

        update new DNAMS_Package__c(Id = pkg().Id, Dealer_Submit_Validation_Override__c = true, Status__c = 'Dealer Submitted');
        Test.getEventBus().deliver();
        List<AI_Package_Review_Run__c> earlier = [SELECT Id FROM AI_Package_Review_Run__c];
        for (AI_Package_Review_Run__c run : earlier) {
            run.Status__c = 'Completed';
        }
        update earlier;

        Assert.isTrue(rerunViaFlow(pkg().Id).contains('new AI review was requested'));
        Test.getEventBus().deliver();

        Assert.areEqual(1, [SELECT COUNT() FROM AI_Package_Review_Run__c WHERE Trigger_Source__c = 'RMR Rerun' AND Status__c = 'Running']);
    }

    // ------------------------------------------------------------------ 21 return to dealer

    @IsTest
    static void returnToDealerSetsReturnedAndEmailsLink() {
        useStubs();
        attach('Org Chart', 'wrong-chart');
        submitAndClassify(); // Dealer Application missing, Org Chart wrong type -> Needs Review
        Assert.areEqual('RMR Pending', pkg().Status__c);

        Assert.isTrue(returnViaFlow(pkg().Id, '').contains('Enter the dealer email'));
        String message = returnViaFlow(pkg().Id, 'principal@example.com');

        Assert.isTrue(message.contains('was returned'), message);
        DNAMS_Package__c returned = pkg();
        Assert.areEqual('Returned', returned.Status__c);
        Assert.areEqual('principal@example.com', returned.Upload_Link_Sent_To__c);
        String again = returnViaFlow(pkg().Id, 'principal@example.com');
        Assert.isTrue(again.contains('Return to Dealer is not available'), again);

        // The dealer page shows each stuck element's narrative after the return.
        String token = [SELECT Upload_Token__c FROM DNAMS_Package__c LIMIT 1].Upload_Token__c;
        DNAMS_GuestUploadController.PackageView view = DNAMS_GuestUploadController.getPackage(token);
        Assert.isTrue(view.elements[1].issue.contains('Found Bank Statement instead of Org Chart'), view.elements[1].issue);
    }

    @IsTest
    static void nonRmrUserIsBlocked() {
        User plain = new User(
            Alias = 'dnamsx',
            Email = 'dnams.plain@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Plain',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User'].Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'dnams.plain.' + System.currentTimeMillis() + '@example.com'
        );
        insert plain;
        Id packageId = pkg().Id;
        System.runAs(plain) {
            Assert.isTrue(cancelViaFlow(packageId).contains('Only RMR'));
        }
    }

    // ------------------------------------------------------------------ 18-20 narrative

    @IsTest
    static void narrativeIsWrittenAndRmrEmailed() {
        useStubs();
        update new DNAMS_Package__c(Id = pkg().Id, OwnerId = UserInfo.getUserId());
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Completed', Issue_Summary__c = '- Org Chart [Failed]: wrong type.');
        insert run;

        new DNAMS_PackageNarrativeQueueable(run.Id).execute(null);

        Assert.isTrue(pkg().AI_Narrative__c.contains('bank statement'));
        Assert.isTrue(reload(run.Id).Reason__c.contains('emailed the package owner'), reload(run.Id).Reason__c);
    }

    @IsTest
    static void narrativeFallsBackWhenModelFails() {
        StubWriter writer = useStubs();
        writer.fail = true;
        update new DNAMS_Package__c(Id = pkg().Id, OwnerId = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'CENTRAL_RMR'].Id);
        AI_Package_Review_Run__c run = new AI_Package_Review_Run__c(Package__c = pkg().Id, Status__c = 'Completed', Issue_Summary__c = '- Org Chart [Failed]: missing.');
        insert run;

        new DNAMS_PackageNarrativeQueueable(run.Id).execute(null);

        Assert.isTrue(pkg().AI_Narrative__c.contains('missing'));
        AI_Package_Review_Run__c after = reload(run.Id);
        Assert.isTrue(after.Error__c.contains('fell back'));
        Assert.isTrue(after.Reason__c.contains('RMR not emailed'), 'Queue/non-RMR owner is recorded only');
    }
}