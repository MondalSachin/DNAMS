/**
 * Diagram steps 18-20 for a run that found issues: writes the AI narrative onto the package (falling back to the
 * plain issue summary if the model fails), then applies the owner check (19) and emails the RMR (20).
 */
public without sharing class DNAMS_PackageNarrativeQueueable implements Queueable, Database.AllowsCallouts {
    public static final String AI_LABEL = 'AI-generated summary - verify before acting.';

    @TestVisible
    private static DNAMS_NarrativeWriter writer = new DNAMS_EinsteinNarrativeWriter();

    private final Id runId;
    private final String subjectSuffix;

    public DNAMS_PackageNarrativeQueueable(Id runId) {
        this(runId, 'document review found issues');
    }

    // Rule validation passes its RAG band in the subject (diagram rule validation step 21).
    public DNAMS_PackageNarrativeQueueable(Id runId, String subjectSuffix) {
        this.runId = runId;
        this.subjectSuffix = subjectSuffix;
    }

    public void execute(QueueableContext context) {
        AI_Package_Review_Run__c run = [SELECT Id, Package__c, Issue_Summary__c FROM AI_Package_Review_Run__c WHERE Id = :runId];
        String narrative;
        String note;
        // Model call first: callouts are not allowed after uncommitted DML.
        try {
            narrative = writer.write(DNAMS_PackageReviewPipelineService.settings().Narrative_Prompt_Template__c, runId);
        } catch (Exception e) {
            narrative = 'Issues found by the document review:\n' + run.Issue_Summary__c;
            note = 'Narrative fell back to the issue summary: ' + e.getTypeName() + ': ' + e.getMessage();
        }
        update new DNAMS_Package__c(Id = run.Package__c, AI_Narrative__c = narrative.left(32768));
        if (note != null) {
            update new AI_Package_Review_Run__c(Id = runId, Error__c = note.left(32768));
        }

        DNAMS_PackageReviewPipelineService.notifyOwners(
            new Map<Id, AI_Package_Review_Run__c>{ run.Package__c => run },
            subjectSuffix,
            AI_LABEL + '\n' + narrative + '\n\nIssues by element:\n' + run.Issue_Summary__c
        );
    }
}