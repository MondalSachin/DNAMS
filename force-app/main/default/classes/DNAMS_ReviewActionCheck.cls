/**
 * Invocable used as the first step of the Re-run Review and Cancel Review flows: checks whether the action is possible
 * now, so the modal shows the confirmation only when it is, and otherwise explains why straight away. Never throws.
 */
public with sharing class DNAMS_ReviewActionCheck {
    @InvocableMethod(label='DNAMS: Check Review Action' description='Checks whether the AI review can be re-run or cancelled, or the package sent or returned to the dealer, now.')
    public static List<Result> check(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                DNAMS_RmrReviewService.ActionCheck check = DNAMS_RmrReviewService.checkAction(request.packageId, request.action);
                result.canProceed = check.canProceed;
                result.message = check.message;
                result.hasChanges = check.hasChanges;
                result.changePreview = toHtml(check.changePreview);
                result.baselineRunName = check.baselineRunName;
            } catch (Exception e) {
                result.canProceed = false;
                result.message = DNAMS_RmrReviewService.failure(e);
            }
            results.add(result);
        }
        return results;
    }

    /**
     * @description Escapes the preview text and keeps its line breaks, for a flow Display Text.
     * @param text Plain multi-line text
     * @return     HTML text, or null when blank
     **/
    private static String toHtml(String text) {
        return String.isBlank(text) ? null : text.escapeHtml4().replace('\n', '<br>');
    }

    public class Request {
        @InvocableVariable(required=true label='Package Id')
        public Id packageId;

        @InvocableVariable(required=true label='Action' description='Rerun, Cancel or SendReturn')
        public String action;
    }

    public class Result {
        @InvocableVariable(label='Can Proceed')
        public Boolean canProceed;

        @InvocableVariable(label='Message')
        public String message;

        @InvocableVariable(label='Has Changes' description='Rerun only: something changed since the last run, so Re-run changes only is possible.')
        public Boolean hasChanges;

        @InvocableVariable(label='Change Preview' description='Rerun only: what changed since the last run (HTML), or why Re-run changes only is not possible.')
        public String changePreview;

        @InvocableVariable(label='Baseline Run Name' description='Rerun only: the run the changes are compared with.')
        public String baselineRunName;
    }
}

