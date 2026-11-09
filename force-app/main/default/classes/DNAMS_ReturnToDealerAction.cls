/** Invocable behind the "Initiate Package/Return to Dealer" Quick Action (flow DNAMS_Return_To_Dealer) on Package. */
public with sharing class DNAMS_ReturnToDealerAction {
    @InvocableMethod(label='DNAMS: Initiate Package or Return to Dealer' description='Draft: sends the upload link and sets Initiated. Initiated: resends it. Later: sets Returned and emails the link with the issues.')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                result.message = DNAMS_RmrReviewService.sendOrReturn(request.packageId);
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
        // Not used any more: the package's Document Uploading Email is the recipient. Kept for older flow versions.
        @InvocableVariable(label='Recipient Email (ignored)')
        public String recipientEmail;
    }

    public class Result {
        @InvocableVariable(label='Message')
        public String message;
    }
}