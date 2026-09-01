from litellm.integrations.custom_logger import CustomLogger


class ReasoningPolicy(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type,
    ):
        """
        Enforce gateway policy that disables model reasoning output.

        Client-supplied reasoning_effort values are overwritten before
        the request is sent to the upstream model.
        """
        data["reasoning_effort"] = "none"
        return data


reasoning_policy = ReasoningPolicy()
