
from enum import Enum
from dataclasses import dataclass
from collections import Counter


# 1. The six established Project1 response states
class ResponseState(str, Enum):
    NOT_SHOWN = "NOT_SHOWN"
    SKIPPED = "SKIPPED"
    REFUSED = "REFUSED"
    ANSWERED_NON_SUBSTANTIVE = "ANSWERED_NON_SUBSTANTIVE"
    INVALID = "INVALID"
    ANSWERED_SUBSTANTIVE = "ANSWERED_SUBSTANTIVE"


# 2. Deterministic contribution rules
# Format: (S, A, V)
#
# IMPORTANT:
# INVALID contributes to A under the CUST03/A10
# interpretation. Final authority reconciliation
# is still required.

COUNTING_RULES = {
    ResponseState.NOT_SHOWN: (0, 0, 0),
    ResponseState.SKIPPED: (1, 0, 0),
    ResponseState.REFUSED: (1, 1, 0),
    ResponseState.ANSWERED_NON_SUBSTANTIVE: (1, 1, 0),
    ResponseState.INVALID: (1, 1, 0),
    ResponseState.ANSWERED_SUBSTANTIVE: (1, 1, 1),
}


# 3. One effective item state per qualified respondent
@dataclass(frozen=True)
class CustomerResponse:
    respondent_id: str
    state: ResponseState


# 4. Evaluate one question for one qualified cohort
def evaluate_responses(responses):
    seen_respondents = set()
    state_counts = Counter()

    Q = len(responses)
    S = 0
    A = 0
    V = 0

    for response in responses:

        if response.respondent_id in seen_respondents:
            raise ValueError(
                f"Duplicate respondent: {response.respondent_id}"
            )

        seen_respondents.add(response.respondent_id)

        if not isinstance(response.state, ResponseState):
            raise ValueError("Invalid response state")

        shown, answered, valid = COUNTING_RULES[response.state]

        S += shown
        A += answered
        V += valid

        state_counts[response.state] += 1

        print(
            f"{response.respondent_id:8} "
            f"{response.state.value:26} "
            f"S={shown} A={answered} V={valid}"
        )

    # 5. Verify measurement invariants
    assert 0 <= V <= A <= S <= Q

    print("\n--- MEASUREMENT SUMMARY ---")
    print(f"Q (Qualified):         {Q}")
    print(f"S (Shown):             {S}")
    print(f"A (Answer events):     {A}")
    print(f"V (Valid substantive): {V}")

    print("\n--- RESPONSE STATE COUNTS ---")
    for state in ResponseState:
        print(f"{state.value:26} {state_counts[state]}")

    print("\n--- MEASUREMENT RATES ---")

    if S > 0:
        print(f"A/S: {A / S * 100:.2f}%")
        print(f"V/S: {V / S * 100:.2f}%")
    else:
        print("A/S: NOT_ESTABLISHED")
        print("V/S: NOT_ESTABLISHED")

    return {
        "Q": Q,
        "S": S,
        "A": A,
        "V": V,
        "response_state_counts": {
            state.value: state_counts[state]
            for state in ResponseState
        }
    }


# 6. Demonstration
# All six respondents are assumed to be qualified.
# These are effective states for ONE question/version.

sample_responses = [
    CustomerResponse("C001", ResponseState.NOT_SHOWN),
    CustomerResponse("C002", ResponseState.SKIPPED),
    CustomerResponse("C003", ResponseState.REFUSED),
    CustomerResponse("C004", ResponseState.ANSWERED_NON_SUBSTANTIVE),
    CustomerResponse("C005", ResponseState.INVALID),
    CustomerResponse("C006", ResponseState.ANSWERED_SUBSTANTIVE),
]


if __name__ == "__main__":
    result = evaluate_responses(sample_responses)
