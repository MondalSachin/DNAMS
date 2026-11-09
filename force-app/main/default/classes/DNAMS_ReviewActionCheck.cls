/**
 * Invocable used as the first step of the Re-run Review and Cancel Review flows: checks whether the action is possible
 * now, so the modal shows the confirmation only when it is, and otherwise explains why straight away. Never throws.
 */
public with sharing class DNAMS_ReviewActionCheck {
    @InvocableMethod(label='DNAMS: Check Review Action' description='Checks whether the AI review can be re-run or cancelled now.')
    public static List<Result> check(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                DNAMS_RmrReviewService.ActionCheck check = DNAMS_RmrReviewService.checkAction(request.packageId, request.action);
                result.canProceed = check.canProceed;
                result.message = check.message;
            } catch (Exception e) {
                result.canProceed = false;
                result.message = DNAMS_RmrReviewService.failure(e);
            }
            results.add(result);
        }
        return results;
    }

    public class Request {
        @InvocableVariable(required=true label='Package Id')
        public Id packageId;

        @InvocableVariable(required=true label='Action' description='Rerun or Cancel')
        public String action;
    }

    public class Result {
        @InvocableVariable(label='Can Proceed')
        public Boolean canProceed;

        @InvocableVariable(label='Message')
        public String message;
    }
}
