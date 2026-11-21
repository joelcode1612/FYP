"""Dedicated-source routing fix; gates remain closed without approval."""
from contextlib import contextmanager
from types import SimpleNamespace
from uuid import UUID
import pytest
from pydantic import SecretStr
import bootstrap
from sitewise.api.v1 import project1_workflow as api
from fastapi import HTTPException

class IdentitySession:
    def __init__(self,identity):self.identity=identity;self.rollbacks=0
    def execute(self,statement):return SimpleNamespace(one=lambda:self.identity)
    def rollback(self):self.rollbacks+=1

def setup(monkeypatch):
    monkeypatch.setattr(api.settings,'project1_workflow_enabled',True)
    monkeypatch.setattr(api.settings,'database_url','postgresql+psycopg2://postgres:test@localhost/Final_Location_Analysis')
    monkeypatch.setattr(api.settings,'m2_database_url',SecretStr('postgresql+psycopg2://p1_m2_runtime:test@localhost/Dss'))

def test_main_marketplace_database_does_not_replace_verified_dedicated_source(monkeypatch):
    setup(monkeypatch);session=IdentitySession(('Dss',False,False))
    api.configuration_gate(session)
    assert session.rollbacks==1
    assert api.settings.database_url.endswith('/Final_Location_Analysis')

@pytest.mark.parametrize('identity',[('Dss',True,False),('Dss',False,True),('Final_Location_Analysis',False,False)])
def test_dedicated_role_and_database_identity_checks_remain_enforced(monkeypatch,identity):
    setup(monkeypatch)
    with pytest.raises(HTTPException,match='503'):api.configuration_gate(IdentitySession(identity))

@pytest.mark.parametrize('url',['postgresql+psycopg2://postgres:test@localhost/Dss',
    'postgresql+psycopg2://role:test@localhost/Final_Location_Analysis','postgresql+psycopg://role:test@localhost/Dss'])
def test_wrong_source_or_driver_and_superuser_are_refused(monkeypatch,url):
    setup(monkeypatch);monkeypatch.setattr(api.settings,'m2_database_url',SecretStr(url))
    with pytest.raises(HTTPException):api.configuration_gate(None)

def test_source_dependency_uses_existing_actor_bound_session(monkeypatch):
    actor=UUID(int=1);calls=[];sentinel=object()
    @contextmanager
    def source(owner):calls.append(owner);yield sentinel
    monkeypatch.setattr(api,'m2_session_for',source)
    dependency=api.get_workflow_source_db(SimpleNamespace(user_id=actor))
    assert next(dependency) is sentinel and calls==[actor]
    dependency.close()

def test_workflow_and_model_approval_switches_still_block(monkeypatch):
    setup(monkeypatch);monkeypatch.setattr(api.settings,'project1_workflow_enabled',False)
    with pytest.raises(HTTPException):api.configuration_gate(None)
    monkeypatch.setattr(api.settings,'tokenharbor_enabled',False)
    with pytest.raises(HTTPException):api.model_assisted_gate()
