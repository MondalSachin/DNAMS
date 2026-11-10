/** Invocable behind the "Re-run Review" Quick Action (flow DNAMS_Rerun_Review) on Package. */
public with sharing class DNAMS_RerunReviewAction {
    @InvocableMethod(label='DNAMS: Re-run AI Review' description='Requests a new AI review of a submitted package.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                result.message = DNAMS_RmrReviewService.rerunReview(request.packageId, request.mode);
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

        @InvocableVariable(label='Mode' description='Changes Only or All (blank = All).')
        public String mode;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }
}