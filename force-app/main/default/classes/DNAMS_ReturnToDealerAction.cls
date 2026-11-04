/** Invocable behind the "Return to Dealer" Quick Action (flow DNAMS_Return_To_Dealer) on Package. */
public with sharing class DNAMS_ReturnToDealerAction {
    @InvocableMethod(label='DNAMS: Return Package to Dealer' description='Sets the package to Returned and emails the dealer the upload link and issues.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                result.message = DNAMS_RmrReviewService.returnToDealer(request.packageId, request.recipientEmail);
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
        @InvocableVariable(label='Recipient Email')
        public String recipientEmail;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }
}