/** Invocable behind the "Cancel Review" Quick Action (flow DNAMS_Cancel_Review) on Package. */
public with sharing class DNAMS_CancelReviewAction {
    @InvocableMethod(label='DNAMS: Cancel AI Review' description='Cancels the AI review in progress on a package.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                result.message = DNAMS_RmrReviewService.cancelReview(request.packageId);
            } catch (Exception e) {
                result.message = DNAMS_RmrReviewService.failure(e);
            }
            results.add(result);
        }
        return results;
    }

    public class Request {
        @InvocableVariable(required=true label='Package Id')
        public Id packageId;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }
}