/**
 * @description     Pre-flight file gate. Before any AI step (classification, extraction) every file on the package's
 *                  elements must be an allowed type (DNAMS_Pipeline_Setting__mdt.AllowedFileExtensions__c, default pdf)
 *                  and no larger than MaxFileSizeMB__c (default 3 MB, the most the Apex IDP submit holds in the async
 *                  heap). Any failing file stops the run here: one error log per problem, Failed elements with a
 *                  narrative, package Health Red, run Needs Review, then the AI narrative, RMR email and Admin email.
 * @author          Abhishek Dutta
 * @group           DNAMS AI Review
 * @last modified on 2026-11-03
 * @last modified by Abhishek Dutta
 * @last modification details Initial version
 * Modifications Log
 * Ver   Date         Author          Modification
 * 1.0   2026-11-03   Abhishek Dutta  Initial version
 **/
public inherited sharing class DNAMSFilePreflightHelper {
    private static final String CLASS_NAME = DNAMSFilePreflightHelper.class.getName();
    private static final Integer NARRATIVE_LENGTH = 255;
    private static final Integer SUMMARY_LENGTH = 32768;
    private static final Decimal BYTES_PER_MB = 1024 * 1024;
    private static final String STAGE_NOT_STARTED = 'Not Started';
    private static final String HEALTH_RED = 'Red';

    /**
     * @description One rejected file and why.
     **/
    public class FileIssue {
        public Id elementId;
        public String elementName;
        public String documentTitle;
        public String errorType;
        public String reason;
    }

    /**
     * @description Checks every file on the run's package; when any file fails, stops the run before any AI step.
     * @param run Locked Running run (Id, Package__c)
     * @return    True when every file passes and the pipeline may continue
     **/
    public static Boolean passesPreflight(AI_Package_Review_Run__c run) {
        List<FileIssue> issues = findIssues(run.Package__c);
        if (issues.isEmpty()) {
            return true;
        }
        stopRun(run, issues);
        return false;
    }

    /**
     * @description Finds every file on the package's elements that has a disallowed type or is too large.
     * @param packageId DNAMS_Package__c id
     * @return          Problems found (empty when all files pass)
     **/
    public static List<FileIssue> findIssues(Id packageId) {
        DNAMS_Pipeline_Setting__mdt setting = DNAMS_PackageReviewPipelineService.settings();
        Decimal maxMegabytes = setting.MaxFileSizeMB__c ?? DNAMSPipelineConstants.DEFAULT_MAX_FILE_SIZE_MB;
        Set<String> allowed = parseExtensions(setting.AllowedFileExtensions__c ?? DNAMSPipelineConstants.DEFAULT_ALLOWED_EXTENSIONS);
        Map<Id, DNAMS_Package_Element__c> elementById = new Map<Id, DNAMS_Package_Element__c>(
            [SELECT Id, Name FROM DNAMS_Package_Element__c WHERE Package__c = :packageId WITH SYSTEM_MODE]
        );
        List<FileIssue> issues = new List<FileIssue>();
        if (elementById.isEmpty()) {
            return issues;
        }
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :elementById.keySet()
            WITH SYSTEM_MODE
        ]) {
            FileIssue template = new FileIssue();
            template.elementId = link.LinkedEntityId;
            template.elementName = elementById.get(link.LinkedEntityId).Name;
            String extension = link.ContentDocument.FileExtension?.toLowerCase();
            template.documentTitle = link.ContentDocument.Title + (String.isBlank(extension) ? '' : '.' + extension);
            addIfPresent(issues, typeIssue(template, extension, allowed));
            addIfPresent(issues, sizeIssue(template, link.ContentDocument.ContentSize, maxMegabytes));
        }
        return issues;
    }

    /**
     * @description Adds the issue when there is one.
     * @param issues Collected issues
     * @param issue  Issue or null
     **/
    private static void addIfPresent(List<FileIssue> issues, FileIssue issue) {
        if (issue != null) {
            issues.add(issue);
        }
    }

    /**
     * @description Invalid File Type issue when the extension is not allowed.
     * @param template  File details
     * @param extension Lower-case file extension (may be blank)
     * @param allowed   Allowed lower-case extensions
     * @return          The issue, or null when the type is allowed
     **/
    private static FileIssue typeIssue(FileIssue template, String extension, Set<String> allowed) {
        if (String.isNotBlank(extension) && allowed.contains(extension)) {
            return null;
        }
        String kind = String.isBlank(extension) ? 'a file without an extension' : 'a ' + extension.toUpperCase() + ' file';
        return copyIssue(template, DNAMSPipelineConstants.ERROR_INVALID_FILE_TYPE,
            '"' + template.documentTitle + '" is ' + kind + '; only ' + String.join(new List<String>(allowed), ', ').toUpperCase()
            + ' files are accepted. Upload it as PDF.');
    }

    /**
     * @description File Too Large issue when the file exceeds the limit.
     * @param template     File details
     * @param sizeBytes    File size in bytes
     * @param maxMegabytes Limit in MB
     * @return             The issue, or null when the file is within the limit
     **/
    private static FileIssue sizeIssue(FileIssue template, Integer sizeBytes, Decimal maxMegabytes) {
        if (sizeBytes == null || sizeBytes <= maxMegabytes * BYTES_PER_MB) {
            return null;
        }
        Decimal sizeMegabytes = (sizeBytes / BYTES_PER_MB).setScale(1);
        return copyIssue(template, DNAMSPipelineConstants.ERROR_FILE_TOO_LARGE,
            '"' + template.documentTitle + '" is ' + sizeMegabytes + ' MB; the limit is ' + maxMegabytes.stripTrailingZeros().toPlainString()
            + ' MB. Upload a smaller copy.');
    }

    /**
     * @description Copies the file details into a new issue of the given type.
     * @param template  File details
     * @param errorType AIReviewErrorLog__c.ErrorType__c value
     * @param reason    Human-readable reason
     * @return          The issue
     **/
    private static FileIssue copyIssue(FileIssue template, String errorType, String reason) {
        FileIssue issue = new FileIssue();
        issue.elementId = template.elementId;
        issue.elementName = template.elementName;
        issue.documentTitle = template.documentTitle;
        issue.errorType = errorType;
        issue.reason = reason;
        return issue;
    }

    /**
     * @description Parses the comma-separated allowed extensions.
     * @param csv Setting value, e.g. "pdf" or "pdf, png"
     * @return    Lower-case extensions without dots
     **/
    private static Set<String> parseExtensions(String csv) {
        Set<String> extensions = new Set<String>();
        for (String part : csv.split(',')) {
            String extension = part.trim().removeStart('.').toLowerCase();
            if (String.isNotBlank(extension)) {
                extensions.add(extension);
            }
        }
        return extensions;
    }

    /**
     * @description Stops the run before any AI step: logs, element and package results, run Needs Review, then the
     *              narrative (which emails the RMR by the owner rule) and the Admin team email.
     * @param run    Locked Running run
     * @param issues File problems
     **/
    private static void stopRun(AI_Package_Review_Run__c run, List<FileIssue> issues) {
        List<AIReviewErrorLog__c> logs = new List<AIReviewErrorLog__c>();
        List<String> summary = new List<String>();
        for (FileIssue issue : issues) {
            logs.add(buildLog(run.Id, issue));
            summary.add('- ' + issue.elementName + ' / ' + issue.documentTitle + ' [' + issue.errorType + ']: ' + issue.reason);
        }
        update as system elementResults(run.Package__c, issues);
        update as system new DNAMS_Package__c(
            Id = run.Package__c,
            Health__c = HEALTH_RED,
            Status__c = DNAMS_PackageReviewPipelineService.PACKAGE_RMR_PENDING,
            AI_Narrative__c = null,
            AI_Narrative_JSON__c = null
        );
        run.Status__c = DNAMS_PackageReviewPipelineService.RUN_COMPLETED;
        run.Classification_Processing_Status__c = DNAMSPipelineConstants.RUN_STAGE_FAILED;
        run.Overall_Result__c = DNAMS_PackageReviewPipelineService.RESULT_NEEDS_REVIEW;
        run.Issue_Summary__c = ('Pre-flight file check stopped the review before any AI step.\n' + String.join(summary, '\n')).left(SUMMARY_LENGTH);
        run.Ended_At__c = System.now();
        update as system run;
        DNAMSErrorLogHelper.insertLogs(logs);
        notify(run.Id, issues.size());
    }

    /**
     * @description Builds the error log for one rejected file.
     * @param runId Review run id
     * @param issue The problem
     * @return      Log record (not inserted)
     **/
    private static AIReviewErrorLog__c buildLog(Id runId, FileIssue issue) {
        DNAMSErrorLogHelper.LogDetail detail = new DNAMSErrorLogHelper.LogDetail();
        detail.runId = runId;
        detail.elementId = issue.elementId;
        detail.stage = DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION;
        detail.errorType = issue.errorType;
        detail.sourceClass = CLASS_NAME;
        detail.documentTitle = issue.documentTitle;
        detail.message = issue.reason;
        return DNAMSErrorLogHelper.buildLog(detail);
    }

    /**
     * @description Element results: elements with a rejected file fail with a narrative; other elements that were set
     *              In Progress by the starter go back to Not Started, because classification never ran.
     * @param packageId Package id
     * @param issues    File problems
     * @return          Elements to update
     **/
    private static List<DNAMS_Package_Element__c> elementResults(Id packageId, List<FileIssue> issues) {
        Map<Id, List<String>> reasonsByElement = new Map<Id, List<String>>();
        for (FileIssue issue : issues) {
            if (!reasonsByElement.containsKey(issue.elementId)) {
                reasonsByElement.put(issue.elementId, new List<String>());
            }
            reasonsByElement.get(issue.elementId).add(issue.reason);
        }
        List<DNAMS_Package_Element__c> updates = new List<DNAMS_Package_Element__c>();
        for (DNAMS_Package_Element__c element : [
            SELECT Id, Classification_Status__c FROM DNAMS_Package_Element__c WHERE Package__c = :packageId WITH SYSTEM_MODE
        ]) {
            List<String> reasons = reasonsByElement.get(element.Id);
            if (reasons != null) {
                String narrative = reasons[0] + (reasons.size() > 1 ? ' (+' + (reasons.size() - 1) + ' more)' : '');
                updates.add(new DNAMS_Package_Element__c(
                    Id = element.Id,
                    Classification_Status__c = DNAMS_PackageReviewPipelineService.STAGE_FAILED,
                    Current_Stage__c = DNAMS_PackageReviewPipelineService.STAGE_CLASSIFICATION,
                    Element_Narrative__c = narrative.left(NARRATIVE_LENGTH)
                ));
            } else if (element.Classification_Status__c == DNAMS_PackageReviewPipelineService.STAGE_IN_PROGRESS) {
                updates.add(new DNAMS_Package_Element__c(Id = element.Id, Classification_Status__c = STAGE_NOT_STARTED));
            }
        }
        return updates;
    }

    /**
     * @description Starts the AI narrative (it emails the RMR by the owner rule) and emails the Admin team.
     * @param runId       Review run id
     * @param issueCount  Number of rejected files
     **/
    private static void notify(Id runId, Integer issueCount) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            // Next step: DNAMS_PackageNarrativeQueueable writes the package AI narrative from Issue_Summary__c
            System.enqueueJob(new DNAMS_PackageNarrativeQueueable(runId));
        }
        DNAMSNotificationHelper.notifyAdminTeam(new Map<Id, String>{
            runId => 'The pre-flight file check stopped the AI review before any AI step: ' + issueCount
                + ' file problem(s) (only allowed file types within the size limit are processed). See the error logs on the run.'
        });
    }
}
