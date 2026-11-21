from hashlib import sha256
from types import SimpleNamespace
from uuid import uuid4

import pytest

from sitewise.repositories.m2_context_bindings import M2ContextBindings
from sitewise.services.business_context_v1 import ContextRefused


def test_selected_confirmed_objective_is_bound_and_tampering_refused():
    owner, assessment, confirmation, objective = (uuid4() for _ in range(4))
    exact = '  SYNTHETIC objective  '
    source = {'assessment_id': str(assessment), 'confirmation_id': str(confirmation),
              'origin': 'ENTREPRENEUR', 'objective_contract': 'entrepreneur-objective/1',
              'objective_version': str(objective), 'owner_user_id': str(owner),
              'owner_decision': 'CONFIRMED', 'approval_status': 'CONFIRMED_BY_OWNER',
              'objective_text_sha256': sha256(exact.encode()).hexdigest()}
    binding = object.__new__(M2ContextBindings)
    binding.repository = SimpleNamespace(read_current_objective=lambda *args: {
        'id': objective, 'exact_text': exact, 'provenance': source})
    selected = binding._uncertainty(confirmation, owner, objective, assessment, 11)
    assert selected['id'] == str(objective) and selected['exact_text'] == exact
    source['confirmation_id'] = str(uuid4())
    with pytest.raises(ContextRefused) as error:
        binding._uncertainty(confirmation, owner, objective, assessment, 11)
    assert error.value.code == 'BCB_OBJECTIVE_SOURCE_UNVERIFIED'
