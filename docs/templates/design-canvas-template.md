# <Feature Name> Design Canvas

## Overview

- **Feature ID**: F<N>
- **Feature Name**: <Feature Name>
- **Status**: Draft / In Review / Approved
- **Author**: <Author Name>
- **Date Created**: YYYY-MM-DD
- **Last Updated**: YYYY-MM-DD

---

## 1. Problem Statement

[Clearly describe the problem this feature is solving]

### User Pain Points
- [Pain point 1]
- [Pain point 2]

### Business Goals
- [Goal 1]
- [Goal 2]

---

## 2. Proposed Solution

[High-level description of the proposed solution]

### Key Features
- [ ] Feature 1
- [ ] Feature 2
- [ ] Feature 3

---

## 3. Architecture

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Architecture                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐         ┌─────────────────┐               │
│  │   Frontend      │────────▶│     API         │               │
│  │   (React/Vue)   │         │   (REST/GraphQL)│               │
│  └─────────────────┘         └────────┬────────┘               │
│                                       │                         │
│                                       ▼                         │
│                              ┌─────────────────┐               │
│                              │    Database     │               │
│                              │                 │               │
│                              └─────────────────┘               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Component Breakdown

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | [Tech] | [Purpose] |
| API | [Tech] | [Purpose] |
| Database | [Tech] | [Purpose] |

---

## 4. Data Flow

### User Flow Diagram

```
User Action → Component → API → Database → Response → UI Update
```

### State Management

[Describe how state is managed]

---

## 5. API Design

### Endpoints

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/v1/resource` | Get list | Required |
| POST | `/api/v1/resource` | Create new | Required |
| PUT | `/api/v1/resource/:id` | Update | Required |
| DELETE | `/api/v1/resource/:id` | Delete | Required |

### Request/Response Schema

```typescript
// Request
interface CreateResourceRequest {
  name: string;
  description?: string;
}

// Response
interface ResourceResponse {
  id: string;
  name: string;
  description: string;
  createdAt: string;
  updatedAt: string;
}
```

---

## 6. Data Model

### Database Schema

```sql
CREATE TABLE resource (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(255) NOT NULL,
  description TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
```

### Entity Relationships

```
Resource (1) ─────< (N) SubResource
    │
    └───< (N) Tag
```

---

## 7. UI Design

### Wireframe/Mockup

[Insert wireframe images or ASCII art representation]

```
┌────────────────────────────────────────────┐
│  Header / Navigation                        │
├────────────────────────────────────────────┤
│                                            │
│  ┌─────────────┐  ┌─────────────────────┐ │
│  │   Sidebar   │  │                     │ │
│  │             │  │    Main Content     │ │
│  │   - Item 1  │  │                     │ │
│  │   - Item 2  │  │   [Feature Area]    │ │
│  │   - Item 3  │  │                     │ │
│  │             │  │                     │ │
│  └─────────────┘  └─────────────────────┘ │
│                                            │
├────────────────────────────────────────────┤
│  Footer                                     │
└────────────────────────────────────────────┘
```

### User Interactions

1. [Interaction 1]: [Description]
2. [Interaction 2]: [Description]

---

## 8. Security Considerations

### Authentication
- [Auth method - e.g., JWT, OAuth]

### Authorization
- [Role-based access rules]

### Data Protection
- [Encryption, PII handling]

---

## 9. Performance Requirements

| Metric | Target | Measurement |
|--------|--------|-------------|
| API Response Time | < 200ms | P95 latency |
| Page Load Time | < 2s | First contentful paint |
| Database Queries | < 50ms | Avg query time |

---

## 10. Dependencies

### External Dependencies
- [Service/Library 1]
- [Service/Library 2]

### Internal Dependencies
- [Module 1]
- [Module 2]

---

## 11. Testing Strategy

### Unit Tests
- [Component/Function to test]

### Integration Tests
- [API integration tests]

### E2E Tests
- [User flow tests]

See: `docs/test-cases/<feature>.md`

---

## 12. Rollout Plan

### Phase 1: Development
- [ ] Design review
- [ ] Implementation
- [ ] Unit tests

### Phase 2: QA
- [ ] Integration testing
- [ ] E2E testing
- [ ] Security review

### Phase 3: Release
- [ ] Staging deployment
- [ ] Production deployment
- [ ] Monitoring setup

---

## 13. Open Questions

- [ ] Question 1?
- [ ] Question 2?

---

## 14. References

- [Link to PRD]
- [Link to related design docs]
- [External references]

---

## Changelog

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| YYYY-MM-DD | 1.0 | <Author> | Initial draft |
